#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

for required_file in README.md Makefile ansible.cfg inventory.ini.example \
  group_vars/all.yml.example site.yml scripts/deploy.sh scripts/benchmark.py; do
  test -f "$repo_root/$required_file"
done

grep -q '^results/$' "$repo_root/.gitignore"
grep -q '^strata_model:' "$repo_root/group_vars/all.yml.example"
