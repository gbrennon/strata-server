#!/usr/bin/env bash
set -euo pipefail

target="${1:-}"
command_parts=(
  "printf '%s\\n' '--- rocm ---'; rocm-smi; "
  "printf '%s\\n' '--- memory ---'; free -h; "
  "printf '%s\\n' '--- strata ---'; "
  "systemctl is-active strata-server.service"
)

command="${command_parts[*]}"
if [[ -n "$target" ]]; then
  ssh "$target" "$command"
else
  bash -lc "$command"
fi
