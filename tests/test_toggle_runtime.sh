#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
script="$repo_root/scripts/toggle-runtime.sh"
test -x "$script"
bash -n "$script"
grep -q 'llama-server.service' "$script"
grep -q 'strata-server.service' "$script"
grep -q '127.0.0.1:8080/health' "$script"
grep -q '127.0.0.1:8082/health' "$script"

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT
cat > "$tmp_dir/systemctl" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$SYSTEMCTL_LOG"
case "$1 $2" in
  "is-active llama-server.service") printf 'active\n' ;;
  "is-active strata-server.service") printf 'inactive\n' ;;
  "is-enabled llama-server.service") printf 'enabled\n' ;;
  "is-enabled strata-server.service") printf 'disabled\n' ;;
esac
FAKE
cat > "$tmp_dir/curl" <<'FAKE'
#!/usr/bin/env bash
if [[ "${CURL_FAIL_STRATA:-0}" == 1 && "$*" == *127.0.0.1:8082/health* ]]; then
  exit 1
fi
exit 0
FAKE
chmod +x "$tmp_dir/systemctl" "$tmp_dir/curl"
SYSTEMCTL_LOG="$tmp_dir/systemctl.log" SYSTEMCTL_BIN="$tmp_dir/systemctl" \
  CURL_BIN="$tmp_dir/curl" SLEEP_BIN=true "$script" strata

grep -q 'stop llama-server.service' "$tmp_dir/systemctl.log"
grep -q 'enable strata-server.service' "$tmp_dir/systemctl.log"
grep -q 'start strata-server.service' "$tmp_dir/systemctl.log"

: > "$tmp_dir/systemctl.log"
if TOGGLE_RUNTIME_ALLOW_NONROOT=1 SYSTEMCTL_LOG="$tmp_dir/systemctl.log" \
  SYSTEMCTL_BIN="$tmp_dir/systemctl" CURL_BIN="$tmp_dir/curl" SLEEP_BIN=true \
  CURL_FAIL_STRATA=1 \
  HEALTH_ATTEMPTS=1 "$script" strata; then
  printf 'Expected Strata startup failure\n' >&2
  exit 1
fi
grep -q 'start llama-server.service' "$tmp_dir/systemctl.log"
