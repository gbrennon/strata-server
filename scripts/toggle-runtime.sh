#!/usr/bin/env bash
set -euo pipefail

systemctl_bin="${SYSTEMCTL_BIN:-systemctl}"
curl_bin="${CURL_BIN:-curl}"
sleep_bin="${SLEEP_BIN:-sleep}"
health_attempts="${HEALTH_ATTEMPTS:-720}"
health_interval="${HEALTH_INTERVAL:-5}"
llama_service="llama-server.service"
strata_service="strata-server.service"
llama_health="http://127.0.0.1:8080/health"
strata_health="http://127.0.0.1:8082/health"

fail() {
  printf '%s\n' "$1" >&2
  exit 2
}

require_root() {
  if [[ "${TOGGLE_RUNTIME_ALLOW_NONROOT:-0}" != 1 && "$(id -u)" != 0 ]]; then
    fail "Run this command as root or with sudo."
  fi
}

service_state() {
  "$systemctl_bin" "$1" "$2" 2>/dev/null || true
}

health_url() {
  case "$1" in
    "$llama_service") printf '%s\n' "$llama_health" ;;
    "$strata_service") printf '%s\n' "$strata_health" ;;
    *) fail "Unknown service: $1" ;;
  esac
}

wait_for_health() {
  local service="$1"
  local url
  local attempt
  url="$(health_url "$service")"
  for ((attempt = 1; attempt <= health_attempts; attempt++)); do
    if "$curl_bin" --fail --silent --show-error "$url" >/dev/null 2>&1; then
      return 0
    fi
    if ((attempt < health_attempts)); then
      "$sleep_bin" "$health_interval"
    fi
  done
  printf 'Health check timed out for %s\n' "$service" >&2
  return 1
}

restore_service_state() {
  local service="$1"
  local enabled="$2"
  local active="$3"
  "$systemctl_bin" stop "$llama_service" >/dev/null 2>&1 || true
  "$systemctl_bin" stop "$strata_service" >/dev/null 2>&1 || true
  if [[ "$enabled" == enabled ]]; then
    "$systemctl_bin" enable "$service" >/dev/null
  else
    "$systemctl_bin" disable "$service" >/dev/null || true
  fi
  if [[ "$active" == active ]]; then
    "$systemctl_bin" start "$service"
    wait_for_health "$service"
  fi
}

health_status() {
  local url="$1"
  "$curl_bin" --fail --silent "$url" >/dev/null 2>&1 && printf healthy || printf unavailable
}

show_status() {
  printf 'llama-server: active=%s enabled=%s health=%s\n' \
    "$(service_state is-active "$llama_service")" \
    "$(service_state is-enabled "$llama_service")" \
    "$(health_status "$llama_health")"
  printf 'strata-server: active=%s enabled=%s health=%s\n' \
    "$(service_state is-active "$strata_service")" \
    "$(service_state is-enabled "$strata_service")" \
    "$(health_status "$strata_health")"
}

switch_runtime() {
  local selected="$1"
  local other
  local previous_service
  local previous_enabled
  local previous_active
  case "$selected" in
    llama) selected="$llama_service"; other="$strata_service" ;;
    strata) selected="$strata_service"; other="$llama_service" ;;
    *) fail "Usage: sudo toggle-ai-runtime {llama|strata|status}" ;;
  esac
  previous_service="$other"
  if [[ "$(service_state is-active "$llama_service")" == active ]]; then
    previous_service="$llama_service"
  elif [[ "$(service_state is-active "$strata_service")" == active ]]; then
    previous_service="$strata_service"
  fi
  previous_enabled="$(service_state is-enabled "$previous_service")"
  previous_active="$(service_state is-active "$previous_service")"
  if ! {
    "$systemctl_bin" stop "$other"
    "$systemctl_bin" disable "$other"
    "$systemctl_bin" enable "$selected"
    "$systemctl_bin" start "$selected"
    wait_for_health "$selected"
  }; then
    restore_service_state "$previous_service" "$previous_enabled" "$previous_active"
    fail "Failed to start $selected; restored $previous_service."
  fi
  printf '%s is healthy.\n' "$selected"
}

require_root
case "${1:-}" in
  status) show_status ;;
  llama|strata) switch_runtime "$1" ;;
  *) fail "Usage: sudo toggle-ai-runtime {llama|strata|status}" ;;
esac
