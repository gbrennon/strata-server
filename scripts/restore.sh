#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
state_file="${STATE_FILE:-$repo_root/deploy_state.json}"
ssh_bin="${SSH_BIN:-ssh}"

[[ -f "$state_file" ]] || {
  printf 'Deployment state does not exist: %s\n' "$state_file" >&2
  exit 2
}

state_target="$(python3 - "$state_file" <<'PY'
import json
import sys
print(json.load(open(sys.argv[1]))["target"])
PY
)"
llama_enabled="$(python3 - "$state_file" <<'PY'
import json
import sys
print(json.load(open(sys.argv[1]))["llama_enabled"])
PY
)"
llama_active="$(python3 - "$state_file" <<'PY'
import json
import sys
print(json.load(open(sys.argv[1]))["llama_active"])
PY
)"

remote() {
  "$ssh_bin" "$state_target" "$1"
}

remote 'sudo systemctl disable --now strata-server.service || true'
if [[ "$llama_enabled" == "enabled" ]]; then
  remote 'sudo systemctl enable llama-server.service'
else
  remote 'sudo systemctl disable llama-server.service'
fi
if [[ "$llama_active" == "active" ]]; then
  remote 'sudo systemctl start llama-server.service'
  remote 'curl --fail --silent --show-error http://127.0.0.1:8080/health' >/dev/null
else
  remote 'sudo systemctl stop llama-server.service'
fi

rm -f "$state_file"
printf 'llama-server restoration completed for %s\n' "$state_target"
