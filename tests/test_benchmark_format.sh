#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

cat > "$tmp_dir/server.py" <<'PY'
import json
from http.server import BaseHTTPRequestHandler, HTTPServer

class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        body = json.dumps({"data": [{"id": "test-model"}]}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.end_headers()
        for token in ("ready", " now"):
            chunk = {"choices": [{"delta": {"content": token}}]}
            self.wfile.write(f"data: {json.dumps(chunk)}\n\n".encode())
            self.wfile.flush()
        self.wfile.write(b"data: [DONE]\n\n")
        self.wfile.flush()

    def log_message(self, format_string, *args):
        return

HTTPServer(("127.0.0.1", 0), Handler).serve_forever()
PY
port_file="$tmp_dir/port"
python3 - "$port_file" <<'PY' &
import json
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        body = b'{"data":[{"id":"test-model"}]}'
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        request_size = int(self.headers.get("Content-Length", "0"))
        request = json.loads(self.rfile.read(request_size) or b"{}")
        if not request.get("stream", False):
            body = b"{\"choices\":[{\"message\":{\"content\":\"ready\"}}]}"
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.end_headers()
        for token in ("ready", " now"):
            chunk = json.dumps({"choices":[{"delta":{"content":token}}]})
            self.wfile.write(f"data: {chunk}\n\n".encode())
            self.wfile.flush()
        self.wfile.write(b"data: [DONE]\n\n")
        self.wfile.flush()

    def log_message(self, format_string, *args):
        return

server = HTTPServer(("127.0.0.1", 0), Handler)
open(sys.argv[1], "w").write(str(server.server_port))
server.serve_forever()
PY
server_pid=$!
while [[ ! -s "$port_file" ]]; do sleep 0.01; done
output="$tmp_dir/report.md"
python3 "$repo_root/scripts/benchmark.py" \
  --base-url "http://127.0.0.1:$(cat "$port_file")" \
  --model test-model --output "$output" >/dev/null
kill "$server_pid"
grep -q 'Time to first token' "$output"
grep -q 'Prompt tokens per second' "$output"
grep -q 'Generated tokens per second' "$output"
grep -q 'test-model' "$output"
grep -q 'UTC' "$output"
