#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
inventory="${INVENTORY:-$repo_root/inventory.ini}"
limit="${LIMIT:-}"
model="${MODEL:-iq3_s}"
port="${STRATA_PORT:-8082}"
state_file="${STATE_FILE:-$repo_root/deploy_state.json}"
ansible_inventory_bin="${ANSIBLE_INVENTORY_BIN:-ansible-inventory}"
ansible_playbook_bin="${ANSIBLE_PLAYBOOK_BIN:-ansible-playbook}"
ssh_bin="${SSH_BIN:-ssh}"
restore_on_error=0

fail() {
  printf '%s\n' "$1" >&2
  exit 2
}

[[ -f "$inventory" ]] || fail "Inventory does not exist: $inventory"
[[ -n "$limit" ]] || fail "LIMIT is required"

resolve_target() {
  local host_data
  host_data="$("$ansible_inventory_bin" -i "$inventory" --host "$limit")"
  ANSIBLE_HOST_DATA="$host_data" python3 - <<'PY'
import json
import os

host_data = json.loads(os.environ["ANSIBLE_HOST_DATA"])
user = host_data.get("ansible_user", "")
host = host_data.get("ansible_host", "")
if not host:
    raise SystemExit("ansible_host is required")
print(f"{user}@{host}" if user else host)
PY
}

remote_target="$(resolve_target)"
remote() {
  "$ssh_bin" "$remote_target" "$1"
}

save_state() {
  local enabled active
  enabled="$(remote 'systemctl is-enabled llama-server.service 2>/dev/null || true' | tail -n 1)"
  active="$(remote 'systemctl is-active llama-server.service 2>/dev/null || true' | tail -n 1)"
  STATE_ENABLED="$enabled" STATE_ACTIVE="$active" STATE_TARGET="$remote_target" \
    STATE_MODEL="$model" STATE_PORT="$port" STATE_TIME="$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    python3 - "$state_file" <<'PY'
import json
import os
import pathlib
import sys

state = {
    "target": os.environ["STATE_TARGET"],
    "llama_enabled": os.environ["STATE_ENABLED"],
    "llama_active": os.environ["STATE_ACTIVE"],
    "model": os.environ["STATE_MODEL"],
    "strata_port": int(os.environ["STATE_PORT"]),
    "captured_at": os.environ["STATE_TIME"],
}
path = pathlib.Path(sys.argv[1])
path.write_text(json.dumps(state, indent=2) + "\n")
path.chmod(0o600)
PY
}

if [[ "${1:-}" == "--check" ]]; then
  exec "$ansible_playbook_bin" -i "$inventory" "$repo_root/site.yml" \
    --limit "$limit" --check --diff \
    -e "strata_model=$model strata_port=$port"
fi

[[ "${1:-}" == "" ]] || fail "Unknown argument: $1"
save_state
restore_on_error=1

recover_after_error() {
  if ((restore_on_error)); then
    STATE_FILE="$state_file" INVENTORY="$inventory" LIMIT="$limit" \
      "$repo_root/scripts/restore.sh" || true
  fi
}

trap recover_after_error ERR

"$ansible_playbook_bin" -i "$inventory" "$repo_root/site.yml" \
  --limit "$limit" -e "strata_model=$model strata_port=$port"

if [[ "$(python3 - "$state_file" <<'PY'
import json
import sys
print(json.load(open(sys.argv[1]))["llama_active"])
PY
)" == "active" ]]; then
  remote 'sudo systemctl disable --now llama-server.service'
else
  remote 'sudo systemctl stop llama-server.service'
fi

remote 'sudo systemctl enable --now strata-server.service'
REMOTE_TARGET="$remote_target" STRATA_PORT="$port" MODEL="$model" \
  "$repo_root/scripts/verify.sh"

restore_on_error=0
printf 'Strata is serving on %s:%s\n' "$remote_target" "$port"
