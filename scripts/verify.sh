#!/usr/bin/env bash
set -euo pipefail

remote_target="${REMOTE_TARGET:-}"
port="${STRATA_PORT:-8082}"
model="${MODEL:-iq3_s}"

while (($# > 0)); do
  case "$1" in
    --remote)
      remote_target="$2"
      shift 2
      ;;
    --port)
      port="$2"
      shift 2
      ;;
    --model)
      model="$2"
      shift 2
      ;;
    *)
      printf 'Unknown argument: %s\n' "$1" >&2
      exit 2
      ;;
  esac
done

run_remote() {
  if [[ -n "$remote_target" ]]; then
    ssh "$remote_target" "$1"
  else
    bash -lc "$1"
  fi
}

run_remote "curl --fail --silent --show-error http://127.0.0.1:${port}/health" >/dev/null
models_json="$(run_remote "curl --fail --silent --show-error http://127.0.0.1:${port}/v1/models")"
python3 -c 'import json, sys; json.load(sys.stdin)' <<<"$models_json"

payload="$(python3 - "$model" <<'PY'
import json
import sys

print(json.dumps({
    "model": sys.argv[1],
    "messages": [{"role": "user", "content": "Reply with the word ready."}],
    "max_tokens": 8,
    "stream": False,
}))
PY
)"

if [[ -n "$remote_target" ]]; then
  printf '%s' "$payload" | ssh "$remote_target" \
    "curl --fail --silent --show-error http://127.0.0.1:${port}/v1/chat/completions \
    -H 'Content-Type: application/json' --data-binary @-" >/dev/null
else
  curl --fail --silent --show-error "http://127.0.0.1:${port}/v1/chat/completions" \
    -H 'Content-Type: application/json' --data "$payload" >/dev/null
fi
