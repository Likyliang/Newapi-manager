#!/usr/bin/env bash
# shellcheck shell=bash

NEWAPI_COMMON_LIB_LOADED=1
NEWAPI_MANAGER_LIB_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
NEWAPI_MANAGER_REPO_ROOT="$(cd "${NEWAPI_MANAGER_LIB_DIR}/../.." && pwd)"

resolve_newapi_manager_config() {
  local candidates=()
  [[ -n "${NEWAPI_MANAGER_CONFIG:-}" ]] && candidates+=("$NEWAPI_MANAGER_CONFIG")
  candidates+=(
    "${NEWAPI_MANAGER_REPO_ROOT}/.env"
    "/etc/newapi-manager.env"
    "/etc/new-api-monitor.env"
    "/etc/app-guard.env"
  )

  local path
  for path in "${candidates[@]}"; do
    if [[ -n "$path" && -f "$path" ]]; then
      printf '%s\n' "$path"
      return 0
    fi
  done
  return 1
}

source_newapi_manager_config() {
  local config_file
  if config_file="$(resolve_newapi_manager_config)"; then
    # shellcheck disable=SC1090
    source "$config_file"
    export NEWAPI_MANAGER_CONFIG_ACTIVE="$config_file"
  else
    export NEWAPI_MANAGER_CONFIG_ACTIVE=""
  fi

  : "${NEWAPI_TZ:=Asia/Shanghai}"
  : "${NEWAPI_URL:=https://example.com/}"
  : "${NEWAPI_NAME:=new-api}"
  : "${NEWAPI_PROXY_NAME:=new-api-proxy}"
  : "${NEWAPI_MYSQL_CONTAINER:=new-api-mysql}"
  : "${NEWAPI_COMPOSE_DIR:=/opt/new-api}"
  : "${NEWAPI_COMPOSE_FILE:=${NEWAPI_COMPOSE_DIR}/docker-compose.yml}"
  : "${NEWAPI_ENV_FILE:=${NEWAPI_COMPOSE_DIR}/.env}"
  : "${NEWAPI_DB_NAME:=new-api}"
  : "${NEWAPI_IMAGE_TAG_KEY:=NEWAPI_IMAGE_TAG}"
  : "${NEWAPI_RELEASES_API_URL:=https://api.github.com/repos/QuantumNous/new-api/releases/latest}"

  : "${NEWAPI_STATE_DIR:=/var/lib/new-api-monitor}"
  : "${NEWAPI_LOG_DIR:=/var/log}"
  : "${NEWAPI_SAMPLE_LOG:=${NEWAPI_LOG_DIR}/new-api-monitor-samples.log}"
  : "${NEWAPI_ALERT_LOG:=${NEWAPI_LOG_DIR}/new-api-monitor-alerts.log}"
  : "${NEWAPI_MONITOR_LOG:=${NEWAPI_LOG_DIR}/new-api-monitor.log}"
  : "${NEWAPI_AUTO_UPDATE_LOG:=${NEWAPI_LOG_DIR}/new-api-auto-update.log}"
  : "${NEWAPI_SYSTEM_REPORT_LOG:=${NEWAPI_LOG_DIR}/new-api-daily-report.log}"
  : "${NEWAPI_BUSINESS_REPORT_LOG:=${NEWAPI_LOG_DIR}/new-api-business-report.log}"
  : "${NEWAPI_DB_BACKUP_LOG:=${NEWAPI_LOG_DIR}/new-api-db-backup.log}"
  : "${NEWAPI_USER_SNAPSHOT_DIR:=/var/lib/newapi-manager/user-snapshots}"

  : "${NEWAPI_DATA_DIR:=${NEWAPI_COMPOSE_DIR}/data}"
  : "${NEWAPI_BRANDING_DIR:=${NEWAPI_COMPOSE_DIR}/branding}"
  : "${NEWAPI_NGINX_CONF:=${NEWAPI_COMPOSE_DIR}/nginx/default.conf}"
  : "${NEWAPI_DB_BACKUP_BASE:=${NEWAPI_COMPOSE_DIR}/backups/db}"

  : "${OPENCLAW_BIN:=/home/lianghao/.local/bin/openclaw}"
  : "${OPENCLAW_CHANNEL:=telegram}"
  : "${OPENCLAW_TARGET:=}"

  : "${NEWAPI_MEM_WARN_MB:=2304}"
  : "${MYSQL_MEM_WARN_MB:=1792}"
  : "${MEM_AVAILABLE_MIN_MB:=192}"
  : "${SWAP_USED_WARN_MB:=1024}"
  : "${FAIL_THRESHOLD:=12}"
  : "${RESTART_COOLDOWN_SEC:=7200}"
  : "${REPORT_TOP_N:=5}"
  : "${REPORT_GROUP_TOP_N:=3}"
  : "${REPORT_PAYMENT_METHOD_TOP_N:=3}"
  : "${BUSINESS_INACTIVE_DAYS:=7}"
  : "${BUSINESS_LONG_INACTIVE_DAYS:=30}"
  : "${REVENUE_SOURCE_CURRENCY:=USD}"
  : "${REVENUE_REPORT_CURRENCY:=CNY}"
  : "${REVENUE_USD_TO_CNY_RATE:=7}"
  : "${REPORT_SEND_DETAIL_MESSAGE:=1}"
  : "${TRAFFIC_TOP_PATHS:=5}"
  : "${TRAFFIC_TOP_SUSPICIOUS_PATHS:=3}"
  : "${TRAFFIC_SUSPICIOUS_REGEX:=([.]env|wp-|vendor/phpunit|boaform|hello[.]world|SDK/|actuator|cgi-bin|login[.]asp|phpunit|[.]git|[.]svn)}"

  : "${OFFSITE_REMOTE_HOST:=}"
  : "${OFFSITE_REMOTE_PATH:=/opt/new-api/backups/db/hourly/latest}"
  : "${OFFSITE_SSH_KEY:=}"
  : "${OFFSITE_BASE_DIR:=/opt/backups/new-api-offsite}"
}

ensure_parent_dir() {
  local target="$1"
  mkdir -p "$(dirname "$target")"
}

ensure_dir() {
  mkdir -p "$1"
}

log_with_ts() {
  local file="$1"
  shift
  ensure_parent_dir "$file"
  printf '[%s] %s\n' "$(date '+%F %T')" "$*" >>"$file"
}

require_command() {
  local cmd
  for cmd in "$@"; do
    command -v "$cmd" >/dev/null 2>&1 || {
      printf 'missing required command: %s\n' "$cmd" >&2
      return 1
    }
  done
}

parse_mem_mb() {
  local token="$1"
  token="${token%%/*}"
  case "$token" in
    *GiB) awk -v v="${token%GiB}" 'BEGIN{printf "%d", v*1024}' ;;
    *MiB) awk -v v="${token%MiB}" 'BEGIN{printf "%d", v}' ;;
    *KiB) awk -v v="${token%KiB}" 'BEGIN{printf "%d", v/1024}' ;;
    *) echo 0 ;;
  esac
}

json_escape() {
  python3 - <<'PY' "$1"
import json, sys
print(json.dumps(sys.argv[1]))
PY
}

html_escape() {
  python3 - <<'PY' "$1"
import html, sys
print(html.escape(sys.argv[1], quote=False))
PY
}

send_notification() {
  local msg="$1"

  if [[ "${NEWAPI_MANAGER_STDOUT_ONLY:-0}" == "1" ]]; then
    printf "%s\n" "$msg"
    return 0
  fi

  if [[ "${NEWAPI_MANAGER_DISABLE_NOTIFY:-0}" == "1" ]]; then
    return 0
  fi

  if [[ -n "${OPENCLAW_TARGET:-}" && -x "${OPENCLAW_BIN:-}" ]]; then
    "$OPENCLAW_BIN" message send \
      --channel "${OPENCLAW_CHANNEL:-telegram}" \
      --target "$OPENCLAW_TARGET" \
      --message "$msg" \
      --json >/dev/null 2>&1 || true
    return 0
  fi

  if [[ -n "${OPENCLAW_WEBHOOK_URL:-}" ]]; then
    local payload
    payload="$(python3 - <<'PY' "$msg"
import json, sys
print(json.dumps({"text": sys.argv[1]}))
PY
)"
    curl -sS -m 10 -X POST "$OPENCLAW_WEBHOOK_URL" \
      -H 'Content-Type: application/json' \
      -d "$payload" >/dev/null 2>&1 || true
    return 0
  fi

  if [[ -n "${TELEGRAM_BOT_TOKEN:-}" && -n "${TELEGRAM_CHAT_ID:-}" ]]; then
    curl -sS -m 10 -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
      -d chat_id="${TELEGRAM_CHAT_ID}" \
      --data-urlencode text="$msg" >/dev/null 2>&1 || true
  fi
}

send_notification_html() {
  local msg="$1"

  if [[ "${NEWAPI_MANAGER_STDOUT_ONLY:-0}" == "1" ]]; then
    printf "%s\n\n" "$msg"
    return 0
  fi

  if [[ "${NEWAPI_MANAGER_DISABLE_NOTIFY:-0}" == "1" ]]; then
    return 0
  fi

  if [[ -n "${TELEGRAM_BOT_TOKEN:-}" && -n "${TELEGRAM_CHAT_ID:-}" ]]; then
    curl -sS -m 10 -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
      -d chat_id="${TELEGRAM_CHAT_ID}" \
      -d parse_mode="HTML" \
      -d disable_web_page_preview="true" \
      --data-urlencode text="$msg" >/dev/null 2>&1 || true
    return 0
  fi

  send_notification "$msg"
}

current_http_code() {
  curl -k -sS -o /dev/null -w '%{http_code}' \
    --connect-timeout 8 \
    --max-time 15 \
    "$NEWAPI_URL" || true
}

compact_number() {
  local value="${1:-0}"
  printf '%s' "$value" | awk '{
    n=$1+0
    if (n>=1000000000) printf "%.2fB", n/1000000000
    else if (n>=1000000) printf "%.2fM", n/1000000
    else if (n>=1000) printf "%.2fK", n/1000
    else printf "%d", n
  }'
}

compact_bytes() {
  local value="${1:-0}"
  printf '%s' "$value" | awk '{
    n=$1+0
    if (n>=1099511627776) printf "%.2fTB", n/1099511627776
    else if (n>=1073741824) printf "%.2fGB", n/1073741824
    else if (n>=1048576) printf "%.2fMB", n/1048576
    else if (n>=1024) printf "%.2fKB", n/1024
    else printf "%dB", n
  }'
}
