#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/../lib/common.sh"

source_newapi_manager_config
require_command curl docker flock awk

STATE_DIR="${NEWAPI_STATE_DIR}"
ALERT_DIR="${STATE_DIR}/alerts"
FAIL_FILE="${STATE_DIR}/fail_count"
LAST_RESTART_FILE="${STATE_DIR}/last_restart_ts"
LOCK_FILE="/var/run/new-api-monitor.lock"

ensure_dir "$STATE_DIR"
ensure_dir "$ALERT_DIR"
ensure_parent_dir "$NEWAPI_SAMPLE_LOG"
ensure_parent_dir "$NEWAPI_ALERT_LOG"
ensure_parent_dir "$LOCK_FILE"

send_alert() {
  send_notification "$1"
}

alert_once() {
  local key="$1"
  local msg="$2"
  local f="$ALERT_DIR/${key}.sent"
  if [[ ! -f "$f" ]]; then
    send_alert "$msg"
    touch "$f"
  fi
}

clear_alert() {
  rm -f "$ALERT_DIR/$1.sent"
}

get_fail_count() {
  [[ -f "$FAIL_FILE" ]] && cat "$FAIL_FILE" 2>/dev/null || echo 0
}

set_fail_count() {
  printf '%s' "$1" >"$FAIL_FILE"
}

exec 9>"$LOCK_FILE"
flock -n 9 || exit 0

now="$(date '+%F %T')"
host="$(hostname)"
load1="$(awk '{print $1}' /proc/loadavg)"
mem_avail_mb="$(awk '/MemAvailable/ {printf "%d", $2/1024}' /proc/meminfo)"
swap_used_mb="$(free -m | awk '/Swap:/ {print $3+0}')"
stats="$(docker stats --no-stream --format '{{.Name}} {{.MemUsage}}' 2>/dev/null || true)"
newapi_mem_token="$(printf '%s\n' "$stats" | awk -v n="$NEWAPI_NAME" '$1==n{print $2; exit}')"
mysql_mem_token="$(printf '%s\n' "$stats" | awk -v n="$NEWAPI_MYSQL_CONTAINER" '$1==n{print $2; exit}')"
newapi_mem_mb=0
mysql_mem_mb=0
[[ -n "$newapi_mem_token" ]] && newapi_mem_mb="$(parse_mem_mb "$newapi_mem_token")"
[[ -n "$mysql_mem_token" ]] && mysql_mem_mb="$(parse_mem_mb "$mysql_mem_token")"

printf '%s host=%s load1=%s mem_avail_mb=%s swap_used_mb=%s newapi_mem_mb=%s mysql_mem_mb=%s\n' \
  "$now" "$host" "$load1" "$mem_avail_mb" "$swap_used_mb" "$newapi_mem_mb" "$mysql_mem_mb" >>"$NEWAPI_SAMPLE_LOG"

reasons=()
(( newapi_mem_mb > NEWAPI_MEM_WARN_MB )) && reasons+=("new-api内存=${newapi_mem_mb}MB>${NEWAPI_MEM_WARN_MB}MB")
(( mysql_mem_mb > MYSQL_MEM_WARN_MB )) && reasons+=("mysql内存=${mysql_mem_mb}MB>${MYSQL_MEM_WARN_MB}MB")
(( mem_avail_mb < MEM_AVAILABLE_MIN_MB )) && reasons+=("MemAvailable=${mem_avail_mb}MB<${MEM_AVAILABLE_MIN_MB}MB")
(( swap_used_mb > SWAP_USED_WARN_MB )) && reasons+=("SwapUsed=${swap_used_mb}MB>${SWAP_USED_WARN_MB}MB")

if (( ${#reasons[@]} > 0 )); then
  local_msg="[new-api-monitor][${host}][${now}] $(IFS='; '; echo "${reasons[*]}")"
  echo "$local_msg" >>"$NEWAPI_ALERT_LOG"
  alert_once resource_pressure "$local_msg"
else
  clear_alert resource_pressure
fi

policy="$(docker inspect -f '{{.HostConfig.RestartPolicy.Name}}' "$NEWAPI_NAME" 2>/dev/null || true)"
if [[ "$policy" != "unless-stopped" ]]; then
  docker update --restart unless-stopped "$NEWAPI_NAME" >/dev/null 2>&1 || true
  alert_once policy_fixed "[new-api-monitor][${host}][${now}] 检测到 ${NEWAPI_NAME} 重启策略被改动，已恢复为 unless-stopped。"
else
  clear_alert policy_fixed
fi

http_code="$(current_http_code)"
reachable=false
if [[ -n "$http_code" && "$http_code" != "000" && "$http_code" -lt 500 ]]; then
  reachable=true
fi

if [[ "$reachable" == true ]]; then
  set_fail_count 0
  clear_alert unreachable_started
  clear_alert unreachable_threshold
  clear_alert restart_cooldown
  clear_alert restarted
  exit 0
fi

count="$(get_fail_count)"
count=$((count + 1))
set_fail_count "$count"
alert_once unreachable_started "[new-api-monitor][${host}][${now}] 外部探测失败: ${NEWAPI_URL} (HTTP=${http_code})，开始计数。"

if (( count < FAIL_THRESHOLD )); then
  exit 0
fi

alert_once unreachable_threshold "[new-api-monitor][${host}][${now}] 外部探测连续失败 ${count} 次（>=${FAIL_THRESHOLD}），准备执行自动恢复。"

now_ts="$(date +%s)"
last_restart=0
[[ -f "$LAST_RESTART_FILE" ]] && last_restart="$(cat "$LAST_RESTART_FILE" 2>/dev/null || echo 0)"
if (( now_ts - last_restart < RESTART_COOLDOWN_SEC )); then
  alert_once restart_cooldown "[new-api-monitor][${host}][${now}] 命中冷却期，暂不再次重启 ${NEWAPI_NAME}。"
  exit 0
fi

action=""
if ! docker inspect "$NEWAPI_NAME" >/dev/null 2>&1; then
  cd "$NEWAPI_COMPOSE_DIR"
  docker compose -f "$NEWAPI_COMPOSE_FILE" up -d "$NEWAPI_NAME" >/dev/null 2>&1 || true
  action="recreate"
else
  running="$(docker inspect -f '{{.State.Running}}' "$NEWAPI_NAME" 2>/dev/null || echo false)"
  if [[ "$running" != "true" ]]; then
    docker start "$NEWAPI_NAME" >/dev/null 2>&1 || true
    action="start"
  else
    docker restart "$NEWAPI_NAME" >/dev/null 2>&1 || true
    action="restart"
  fi
fi

printf '%s' "$now_ts" >"$LAST_RESTART_FILE"
alert_once restarted "[new-api-monitor][${host}][${now}] 外部持续不可用，已执行自动恢复动作: ${action}。"
