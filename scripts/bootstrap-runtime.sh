#!/usr/bin/env bash
set -euo pipefail

ssh_target="${SSH_TARGET:-gbrennon-local-ai@192.168.0.2}"
models_file="${PI_MODELS_FILE:-$HOME/.pi/agent/models.json}"
state_dir="${STATE_DIR:-$HOME/.local/state/strata-server-toggle}"
local_api_port="${LOCAL_API_PORT:-18080}"
ssh_bin="${SSH_BIN:-ssh}"
curl_bin="${CURL_BIN:-curl}"
remote_toggle_command="${REMOTE_TOGGLE_COMMAND:-/usr/local/bin/toggle-ai-runtime}"
health_attempts="${HEALTH_ATTEMPTS:-30}"
health_interval="${HEALTH_INTERVAL:-1}"
tunnel_pid_file="$state_dir/tunnel.pid"
runtime_file="$state_dir/runtime"

fail() {
  printf '%s\n' "$1" >&2
  exit 2
}

runtime_settings() {
  case "$1" in
    strata)
      remote_port=8082
      provider_name=gbrennon-strata
      ;;
    llama)
      remote_port=8080
      provider_name=gbrennon-llama
      ;;
    *)
      fail "Usage: $0 {strata|llama|status}"
      ;;
  esac
  health_url="http://127.0.0.1:${local_api_port}/health"
  models_url="http://127.0.0.1:${local_api_port}/v1/models"
  completions_url="http://127.0.0.1:${local_api_port}/v1/chat/completions"
}

terminate_tunnel_process() {
  local tunnel_pid="$1"
  [[ "$tunnel_pid" =~ ^[0-9]+$ ]] || return 0
  kill -0 "$tunnel_pid" 2>/dev/null || return 0
  kill "$tunnel_pid" 2>/dev/null || true
  wait "$tunnel_pid" 2>/dev/null || true
}

stop_tunnel() {
  [[ -f "$tunnel_pid_file" ]] || return 0
  terminate_tunnel_process "$(<"$tunnel_pid_file")"
  rm -f "$tunnel_pid_file"
}

wait_for_health() {
  local attempt
  for ((attempt = 1; attempt <= health_attempts; attempt++)); do
    if "$curl_bin" --fail --silent --show-error "$health_url" >/dev/null 2>&1; then
      return 0
    fi
    if ((attempt < health_attempts)); then
      sleep "$health_interval"
    fi
  done
  return 1
}

start_tunnel() {
  local tunnel_pid
  mkdir -p "$state_dir"
  nohup "$ssh_bin" -N -o ExitOnForwardFailure=yes \
    -L "${local_api_port}:127.0.0.1:${remote_port}" "$ssh_target" \
    >/dev/null 2>&1 &
  tunnel_pid=$!
  printf '%s\n' "$tunnel_pid" > "$tunnel_pid_file"
  if ! wait_for_health; then
    stop_tunnel
    fail "The ${provider_name} API did not become healthy through the SSH tunnel."
  fi
}

read_model_id() {
  local models_json="$1"
  MODELS_JSON="$models_json" python3 - <<'PY'
import json
import os

listing = json.loads(os.environ["MODELS_JSON"])
models = listing.get("data", [])
if not models or not models[0].get("id"):
    raise SystemExit("The /v1/models response did not contain a model ID")
print(models[0]["id"])
PY
}

verify_api() {
  local models_json
  local model_id
  local payload
  models_json="$("$curl_bin" --fail --silent --show-error "$models_url")" || \
    fail "The ${provider_name} /v1/models request failed."
  model_id="$(read_model_id "$models_json")" || fail "Could not read the active model ID."
  payload="$(MODEL_ID="$model_id" python3 - <<'PY'
import json
import os

print(json.dumps({
    "model": os.environ["MODEL_ID"],
    "messages": [{"role": "user", "content": "Reply with exactly READY."}],
    "max_tokens": 8,
    "stream": False,
}))
PY
)"
  "$curl_bin" --fail --silent --show-error \
    -H 'Content-Type: application/json' --data "$payload" "$completions_url" \
    >/dev/null || fail "The ${provider_name} chat completion request failed."
  printf '%s\n' "$model_id"
}

clean_pi_provider_duplicates() {
  local backup_file
  local parent_dir
  parent_dir="$(dirname "$models_file")"
  mkdir -p "$parent_dir" "$state_dir"
  if [[ -f "$models_file" ]]; then
    backup_file="${models_file}.$(date -u +%Y%m%dT%H%M%SZ).bak"
    cp -- "$models_file" "$backup_file"
  fi
  MODELS_FILE="$models_file" python3 - <<'PY'
import json
import os
import pathlib
import tempfile

path = pathlib.Path(os.environ["MODELS_FILE"])
data = json.loads(path.read_text()) if path.exists() else {}
providers = data.setdefault("providers", {})
if not isinstance(providers, dict):
    raise SystemExit("Pi models.json providers must be an object")
for provider in (
    "evo-x2-llama",
    "local-llama-cpp",
    "gbrennon-llama",
    "gbrennon-strata",
):
    providers.pop(provider, None)
file_descriptor, temporary_name = tempfile.mkstemp(
    dir=path.parent,
    prefix=f".{path.name}.",
    suffix=".tmp",
    text=True,
)
os.close(file_descriptor)
temporary_path = pathlib.Path(temporary_name)
temporary_path.chmod(0o600)
temporary_path.write_text(json.dumps(data, indent=2) + "\n")
os.replace(temporary_path, path)
PY
  printf '%s\n' "$runtime" > "$runtime_file"
}

read_runtime_label() {
  [[ -f "$runtime_file" ]] || { printf 'inactive\n'; return 0; }
  printf '%s\n' "$(<"$runtime_file")"
}

read_active_provider() {
  [[ -f "$models_file" ]] || { printf 'none\n'; return 0; }
  MODELS_FILE="$models_file" python3 - <<'PY'
import json
import os

providers = json.loads(open(os.environ["MODELS_FILE"]).read()).get("providers", {})
print("gbrennon-server" if "gbrennon-server" in providers else "none")
PY
}

tunnel_is_active() {
  [[ -f "$tunnel_pid_file" ]] || return 1
  kill -0 "$(<"$tunnel_pid_file")" 2>/dev/null
}

api_health_label() {
  local runtime="$1"
  [[ "$runtime" != inactive ]] || { printf 'unknown'; return 0; }
  runtime_settings "$runtime"
  if "$curl_bin" --fail --silent "$health_url" >/dev/null 2>&1; then
    printf 'healthy'
  else
    printf 'unhealthy'
  fi
}

status() {
  local runtime provider
  runtime="$(read_runtime_label)"
  provider="$(read_active_provider)"
  printf 'runtime=%s provider=%s tunnel=' "$runtime" "$provider"
  if tunnel_is_active; then
    printf 'active api=%s\n' "$(api_health_label "$runtime")"
  else
    printf 'inactive api=unavailable\n'
  fi
}

runtime="${1:-}"
if [[ "$runtime" == status ]]; then
  status
  exit 0
fi
runtime_settings "$runtime"
"$ssh_bin" "$ssh_target" "sudo ${remote_toggle_command} ${runtime}" || \
  fail "Could not switch the remote runtime to ${runtime}."
stop_tunnel
start_tunnel
model_id="$(verify_api)"
clean_pi_provider_duplicates
printf '%s active; canonical Pi provider gbrennon-server is preserved (model %s).\n' \
  "$runtime" "$model_id"
