#!/usr/bin/env python3
"""Measure an OpenAI-compatible Strata endpoint and write a Markdown report."""

from __future__ import annotations

import argparse
import json
import os
import socket
import subprocess
import time
from contextlib import contextmanager
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Iterator, Mapping, Sequence
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen

JsonObject = dict[str, object]


@dataclass(frozen=True)
class CompletionMeasurement:
    """Stores timing and token values for one streamed completion."""

    model: str
    prompt_tokens: int
    completion_tokens: int
    max_tokens: int
    started_at: float
    first_token_at: float
    finished_at: float
    estimated_tokens: bool

    @property
    def time_to_first_token(self) -> float:
        """Returns seconds between request start and the first generated token."""
        return self.first_token_at - self.started_at

    @property
    def duration(self) -> float:
        """Returns seconds between request start and stream completion."""
        return self.finished_at - self.started_at

    @property
    def prompt_rate(self) -> float:
        """Returns prompt tokens processed per second."""
        return self.prompt_tokens / self.time_to_first_token

    @property
    def generation_rate(self) -> float:
        """Returns generated tokens produced per second."""
        generation_time = self.finished_at - self.first_token_at
        return self.completion_tokens / generation_time if generation_time else 0.0


def parse_args() -> argparse.Namespace:
    """Parses benchmark command-line arguments."""
    parser = argparse.ArgumentParser()
    parser.add_argument("--base-url", default="http://127.0.0.1:8082")
    parser.add_argument("--model", default="")
    parser.add_argument("--output", default="")
    parser.add_argument(
        "--prompt",
        default="Explain ROCm GPU offloading in three concise paragraphs.",
    )
    parser.add_argument("--max-tokens", type=int, default=256)
    parser.add_argument("--api-key", default="")
    parser.add_argument("--ssh-target", default="")
    parser.add_argument("--remote-port", type=int, default=8082)
    return parser.parse_args()


def as_object(value: object) -> JsonObject:
    """Returns a JSON object or raises a descriptive type error."""
    if not isinstance(value, dict):
        raise TypeError("Expected a JSON object")
    return {str(key): item for key, item in value.items()}


def as_sequence(value: object) -> Sequence[object]:
    """Returns a JSON sequence or raises a descriptive type error."""
    if not isinstance(value, list):
        raise TypeError("Expected a JSON array")
    return value


def request_json(url: str, payload: JsonObject | None, api_key: str) -> JsonObject:
    """Sends an HTTP request and decodes its JSON response."""
    body = None if payload is None else json.dumps(payload).encode()
    headers = {"Accept": "application/json"}
    if payload is not None:
        headers["Content-Type"] = "application/json"
    if api_key:
        headers["Authorization"] = f"Bearer {api_key}"
    request = Request(url, data=body, headers=headers, method="POST" if body else "GET")
    try:
        with urlopen(request, timeout=60) as response:
            return as_object(json.load(response))
    except (HTTPError, URLError) as error:
        raise RuntimeError(f"HTTP request failed: {error}") from error


def model_from_listing(listing: JsonObject) -> str:
    """Returns the first model identifier advertised by the endpoint."""
    entries = as_sequence(listing.get("data", []))
    if not entries:
        raise RuntimeError("The endpoint returned no models")
    first = as_object(entries[0])
    identifier = first.get("id") or first.get("name") or first.get("model")
    if not isinstance(identifier, str) or not identifier:
        raise RuntimeError("The endpoint returned a model without an identifier")
    return identifier


def estimated_token_count(text: str) -> int:
    """Estimates token count when the server omits usage metadata."""
    return max(1, round(len(text.split()) * 1.3))


def stream_completion(
    url: str,
    model: str,
    prompt: str,
    max_tokens: int,
    api_key: str,
) -> CompletionMeasurement:
    """Streams one completion and calculates timing and throughput values."""
    payload: JsonObject = {
        "model": model,
        "messages": [{"role": "user", "content": prompt}],
        "max_tokens": max_tokens,
        "stream": True,
        "stream_options": {"include_usage": True},
    }
    body = json.dumps(payload).encode()
    headers = {"Content-Type": "application/json", "Accept": "text/event-stream"}
    if api_key:
        headers["Authorization"] = f"Bearer {api_key}"
    request = Request(url, data=body, headers=headers, method="POST")
    started_at = time.perf_counter()
    first_token_at = 0.0
    finished_at = started_at
    pieces: list[str] = []
    usage: JsonObject = {}
    try:
        response = urlopen(request, timeout=600)
        with response:
            for raw_line in response:
                line = raw_line.decode("utf-8", errors="replace").strip()
                if not line.startswith("data:"):
                    continue
                data = line[5:].strip()
                if data == "[DONE]":
                    break
                chunk = as_object(json.loads(data))
                usage_value = chunk.get("usage")
                if isinstance(usage_value, dict):
                    usage = as_object(usage_value)
                pieces.extend(content_fragments(chunk))
                if pieces and first_token_at == 0.0:
                    first_token_at = time.perf_counter()
            finished_at = time.perf_counter()
    except (HTTPError, URLError) as error:
        raise RuntimeError(f"Streaming request failed: {error}") from error
    if first_token_at == 0.0:
        raise RuntimeError("The endpoint emitted no content tokens")
    prompt_tokens = integer_value(usage.get("prompt_tokens"))
    completion_tokens = integer_value(usage.get("completion_tokens"))
    estimated = prompt_tokens == 0 or completion_tokens == 0
    return CompletionMeasurement(
        model=model,
        prompt_tokens=prompt_tokens or estimated_token_count(prompt),
        completion_tokens=completion_tokens or estimated_token_count("".join(pieces)),
        max_tokens=max_tokens,
        started_at=started_at,
        first_token_at=first_token_at,
        finished_at=finished_at,
        estimated_tokens=estimated,
    )


def content_fragments(chunk: JsonObject) -> list[str]:
    """Extracts generated text fragments from an OpenAI stream chunk."""
    fragments: list[str] = []
    for choice_value in as_sequence(chunk.get("choices", [])):
        choice = as_object(choice_value)
        delta = as_object(choice.get("delta", {}))
        content = delta.get("content")
        if isinstance(content, str):
            fragments.append(content)
    return fragments


def integer_value(value: object) -> int:
    """Converts a JSON numeric value to a nonnegative integer."""
    return value if isinstance(value, int) and value >= 0 else 0


def collect_system_info(ssh_target: str) -> str:
    """Collects non-secret hardware and service information."""
    command = (
        "printf '%s\\n' '--- rocm ---'; rocm-smi; "
        "printf '%s\\n' '--- vram ---'; rocm-smi --showmeminfo vram; "
        "printf '%s\\n' '--- device ---'; "
        "rocminfo | grep -E 'Marketing Name:|Name:.*gfx' | head -10; "
        "printf '%s\\n' '--- memory ---'; free -h; "
        "printf '%s\\n' '--- strata ---'; strata --version; "
        "printf '%s\\n' '--- service ---'; "
        "systemctl is-active strata-server.service"
    )
    if ssh_target:
        result = subprocess.run(
            ["ssh", ssh_target, command],
            check=False,
            capture_output=True,
            text=True,
        )
    else:
        result = subprocess.run(
            ["bash", "-lc", command],
            check=False,
            capture_output=True,
            text=True,
        )
    return (result.stdout + result.stderr).strip()


@contextmanager
def endpoint_context(args: argparse.Namespace) -> Iterator[str]:
    """Creates an SSH tunnel when the endpoint is remote."""
    if not args.ssh_target:
        yield args.base_url.rstrip("/")
        return
    local_port = free_port()
    tunnel = subprocess.Popen(
        [
            "ssh",
            "-o",
            "ExitOnForwardFailure=yes",
            "-N",
            "-L",
            f"{local_port}:127.0.0.1:{args.remote_port}",
            args.ssh_target,
        ],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.PIPE,
        text=True,
    )
    try:
        wait_for_port(local_port, tunnel)
        yield f"http://127.0.0.1:{local_port}"
    finally:
        tunnel.terminate()
        tunnel.wait(timeout=10)


def free_port() -> int:
    """Returns an available local TCP port."""
    with socket.socket() as listener:
        listener.bind(("127.0.0.1", 0))
        return int(listener.getsockname()[1])


def wait_for_port(port: int, process: subprocess.Popen[str]) -> None:
    """Waits for an SSH tunnel or raises its startup error."""
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline:
        if process.poll() is not None:
            details = process.stderr.read() if process.stderr else ""
            raise RuntimeError(f"SSH tunnel failed: {details}")
        try:
            with socket.create_connection(("127.0.0.1", port), timeout=0.2):
                return
        except OSError:
            time.sleep(0.1)
    raise RuntimeError("SSH tunnel did not become ready")


def output_path(value: str) -> Path:
    """Returns the requested or timestamped report path."""
    if value:
        return Path(value)
    timestamp = datetime.now(timezone.utc).strftime("%Y%m%d-%H%M%S")
    return Path("results") / f"strata-{timestamp}.md"


def render_report(
    measurement: CompletionMeasurement,
    prompt: str,
    endpoint: str,
    system_info: str,
    started: datetime,
) -> str:
    """Renders benchmark measurements as a Markdown document."""
    token_note = "estimated" if measurement.estimated_tokens else "reported by server"
    return "\n".join(
        [
            "# Strata Benchmark Report",
            "",
            f"- UTC: {started.isoformat()}",
            f"- Endpoint: `{endpoint}`",
            f"- Model: `{measurement.model}`",
            f"- Token counts: {token_note}",
            "",
            "## Timing",
            "",
            f"- Time to first token: `{measurement.time_to_first_token:.3f} s`",
            f"- Total duration: `{measurement.duration:.3f} s`",
            f"- Prompt tokens per second: `{measurement.prompt_rate:.2f}`",
            f"- Generated tokens per second: `{measurement.generation_rate:.2f}`",
            "",
            "## Request",
            "",
            f"- Maximum output tokens: `{measurement.max_tokens}`",
            f"- Prompt: {prompt}",
            "",
            "## System Information",
            "",
            "```text",
            system_info,
            "```",
            "",
            "## Limitations",
            "",
            "- One warm-up request and one measured streamed request were used.",
            "- Token counts are estimated when the server omits usage metadata.",
            "- The report measures endpoint behavior, not a controlled laboratory benchmark.",
            "",
        ]
    )


def write_report(path: Path, content: str) -> None:
    """Writes a report atomically and creates its parent directory."""
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary_path = path.with_suffix(path.suffix + ".tmp")
    temporary_path.write_text(content, encoding="utf-8")
    os.replace(temporary_path, path)


def main() -> None:
    """Runs the benchmark and writes the workstation report."""
    args = parse_args()
    started = datetime.now(timezone.utc)
    with endpoint_context(args) as endpoint:
        listing = request_json(f"{endpoint}/v1/models", None, args.api_key)
        model = args.model or model_from_listing(listing)
        warmup = {
            "model": model,
            "messages": [{"role": "user", "content": "Say ready."}],
            "max_tokens": 8,
            "stream": False,
        }
        request_json(f"{endpoint}/v1/chat/completions", warmup, args.api_key)
        measurement = stream_completion(
            f"{endpoint}/v1/chat/completions",
            model,
            args.prompt,
            args.max_tokens,
            args.api_key,
        )
    report = render_report(
        measurement,
        args.prompt,
        endpoint,
        collect_system_info(args.ssh_target),
        started,
    )
    path = output_path(args.output)
    write_report(path, report)
    print(path)


if __name__ == "__main__":
    main()
