#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
for file in README.md docs/operations.md docs/benchmarking.md Makefile; do
  test -f "$repo_root/$file"
done
grep -q '192.168.0.2' "$repo_root/docs/operations.md"
grep -q 'llama-server' "$repo_root/docs/operations.md"
grep -q 'make restore' "$repo_root/docs/operations.md"
grep -q 'results/' "$repo_root/docs/benchmarking.md"
