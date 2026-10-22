#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
for required_file in site.yml roles/preflight/tasks/main.yml \
  roles/strata/tasks/main.yml roles/strata/templates/strata-server.service.j2 \
  roles/strata/handlers/main.yml; do
  test -f "$repo_root/$required_file"
done
grep -q 'llama_service_name' "$repo_root/roles/preflight/tasks/main.yml"
grep -q 'strata_port' "$repo_root/roles/strata/templates/strata-server.service.j2"
grep -q 'User={{ strata_user }}' "$repo_root/roles/strata/templates/strata-server.service.j2"
