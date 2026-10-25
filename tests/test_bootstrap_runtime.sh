#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
script="$repo_root/scripts/bootstrap-runtime.sh"
test -x "$script"
bash -n "$script"

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

cat > "$tmp_dir/ssh" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$SSH_LOG"
if [[ "$*" == *"toggle-ai-runtime"* ]]; then
  exit 0
fi
if [[ "$*" == *"127.0.0.1:8080"* || "$*" == *"127.0.0.1:8082"* ]]; then
  while true; do sleep 1; done
fi
exit 0
FAKE

cat > "$tmp_dir/curl" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${CURL_FAIL:-0}" == 1 ]]; then
  exit 1
fi
url="${@: -1}"
case "$url" in
  */health) printf '{"status":"ok"}\n' ;;
  */v1/models) printf '{"data":[{"id":"qwen3.8-flash-next-iq3_s"}]}\n' ;;
  */v1/chat/completions) printf '{"choices":[{"message":{"content":"READY"}}]}\n' ;;
  *) exit 1 ;;
esac
FAKE
chmod +x "$tmp_dir/ssh" "$tmp_dir/curl"

models_file="$tmp_dir/models.json"
cat > "$models_file" <<'JSON'
{
  "providers": {
    "other": {"baseUrl": "http://other/v1"},
    "gbrennon-server": {"models": [{"id": "Qwen3-Coder"}]},
    "evo-x2-llama": {"models": [{"id": "old"}]},
    "local-llama-cpp": {"models": [{"id": "old"}]},
    "gbrennon-llama": {"models": [{"id": "old"}]},
    "gbrennon-strata": {"models": [{"id": "old"}]}
  }
}
JSON
state_dir="$tmp_dir/state"
SSH_LOG="$tmp_dir/ssh.log" SSH_BIN="$tmp_dir/ssh" CURL_BIN="$tmp_dir/curl" \
  PI_MODELS_FILE="$models_file" STATE_DIR="$state_dir" \
  TOGGLE_RUNTIME_ALLOW_NONROOT=1 "$script" strata

grep -q 'sudo /usr/local/bin/toggle-ai-runtime strata' "$tmp_dir/ssh.log"
grep -q '127.0.0.1:8082' "$tmp_dir/ssh.log"
python3 - "$models_file" <<'PY'
import json
import sys

providers = json.load(open(sys.argv[1]))["providers"]
assert list(providers) == ["other", "gbrennon-server"]
assert providers["gbrennon-server"]["models"][0]["id"] == "Qwen3-Coder"
for duplicate in ("evo-x2-llama", "local-llama-cpp", "gbrennon-llama", "gbrennon-strata"):
    assert duplicate not in providers
PY

backup_count="$(find "$tmp_dir" -name 'models.json.*.bak' | wc -l)"
test "$backup_count" -eq 1

kill "$(cat "$state_dir/tunnel.pid")" 2>/dev/null || true
printf '%s\n' '{"providers":{"other":{"baseUrl":"http://other/v1"}}}' > "$models_file"
SSH_LOG="$tmp_dir/ssh.log" SSH_BIN="$tmp_dir/ssh" CURL_BIN="$tmp_dir/curl" \
  PI_MODELS_FILE="$models_file" STATE_DIR="$state_dir" \
  TOGGLE_RUNTIME_ALLOW_NONROOT=1 "$script" llama

grep -q 'sudo /usr/local/bin/toggle-ai-runtime llama' "$tmp_dir/ssh.log"
grep -q '127.0.0.1:8080' "$tmp_dir/ssh.log"
python3 - "$models_file" <<'PY'
import json
import sys

providers = json.load(open(sys.argv[1]))["providers"]
assert list(providers) == ["other"]
PY
kill "$(cat "$state_dir/tunnel.pid")" 2>/dev/null || true
original_models="$(cat "$models_file")"
if SSH_LOG="$tmp_dir/ssh.log" SSH_BIN="$tmp_dir/ssh" CURL_BIN="$tmp_dir/curl" \
  CURL_FAIL=1 HEALTH_ATTEMPTS=1 PI_MODELS_FILE="$models_file" STATE_DIR="$state_dir" \
  TOGGLE_RUNTIME_ALLOW_NONROOT=1 "$script" strata; then
  printf 'Expected API failure\n' >&2
  exit 1
fi
test "$original_models" = "$(cat "$models_file")"
status_output="$(SSH_BIN="$tmp_dir/ssh" CURL_BIN="$tmp_dir/curl" \
  PI_MODELS_FILE="$models_file" STATE_DIR="$state_dir" \
  TOGGLE_RUNTIME_ALLOW_NONROOT=1 "$script" status)"
grep -q 'provider=none' <<<"$status_output"
grep -q 'tunnel=inactive' <<<"$status_output"
printf 'bootstrap runtime tests passed\n'
