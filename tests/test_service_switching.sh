#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
for script in deploy.sh restore.sh verify.sh; do
  test -x "$repo_root/scripts/$script"
done

grep -q 'systemctl stop llama-server' "$repo_root/scripts/deploy.sh"
grep -q 'systemctl start llama-server' "$repo_root/scripts/restore.sh"
grep -q '/v1/chat/completions' "$repo_root/scripts/verify.sh"
