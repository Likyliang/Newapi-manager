#!/usr/bin/env bash
set -euo pipefail

SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(cd "$(dirname "${SCRIPT_PATH}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/../lib/common.sh"

source_newapi_manager_config
require_command curl docker awk grep cut free df date sort head mktemp

REPORT_DATE="${1:-$(date -d 'yesterday' +%F)}"
NEXT_DATE="$(date -d "${REPORT_DATE} +1 day" +%F)"
REPORT_TITLE="new-api 系统日报（${REPORT_DATE}）"
REPORT_HOST="$(hostname)"
NOW="$(date '+%F %T')"
TOP_PATHS="${TRAFFIC_TOP_PATHS}"
TOP_SUSPICIOUS_PATHS="${TRAFFIC_TOP_SUSPICIOUS_PATHS}"
SUSPICIOUS_REGEX="${TRAFFIC_SUSPICIOUS_REGEX}"

LOG_TMP="$(mktemp)"
trap 'rm -f "$LOG_TMP"' EXIT

container_line() {
  local name="$1"
  local status health restart mem
  status="$(docker inspect -f '{{.State.Status}}' "$name" 2>/dev/null || echo 'missing')"
  health="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}n/a{{end}}' "$name" 2>/dev/null || echo 'n/a')"
  restart="$(docker inspect -f '{{.RestartCount}}' "$name" 2>/dev/null || echo '0')"
  mem="$(docker stats --no-stream --format '{{.Name}} {{.MemUsage}}' 2>/dev/null | awk -v n="$name" '$1==n{print $2; exit}')"
  [[ -n "$mem" ]] || mem="n/a"
  printf '%s|%s|%s|%s|%s\n' "$name" "$status" "$health" "$restart" "$mem"
}

get_field() {
  local line="$1" idx="$2"
  printf '%s' "$line" | cut -d'|' -f"$idx"
}

fmt_container() {
  local line="$1"
  printf '%s: %s / health=%s / restart=%s / mem=%s' \
    "$(get_field "$line" 1)" \
    "$(get_field "$line" 2)" \
    "$(get_field "$line" 3)" \
    "$(get_field "$line" 4)" \
    "$(get_field "$line" 5)"
}

format_count_path_lines() {
  local raw="$1"
  local empty_label="$2"
  if [[ -z "$raw" ]]; then
    printf '  - %s\n' "$empty_label"
    return 0
  fi
  local idx=0
  while IFS=$'\t' read -r count path; do
    [[ -n "${path:-}" ]] || continue
    idx=$((idx + 1))
    printf '  %d) %s ｜ %s\n' "$idx" "$path" "$count"
  done <<<"$raw"
}

current_http="$(current_http_code)"
current_swap_used="$(free -m | awk '/Swap:/ {print $3+0}')"
current_mem_avail="$(awk '/MemAvailable/ {printf "%d", $2/1024}' /proc/meminfo)"
current_load1="$(awk '{print $1}' /proc/loadavg)"
current_disk_root="$(df -h / | awk 'NR==2{print $5" used, free=" $4}')"
current_disk_opt="$(df -h /opt 2>/dev/null | awk 'NR==2{print $5" used, free=" $4}' || echo 'n/a')"

newapi_line="$(container_line "$NEWAPI_NAME")"
mysql_line="$(container_line "$NEWAPI_MYSQL_CONTAINER")"
proxy_line="$(container_line "$NEWAPI_PROXY_NAME")"

docker logs --since "${REPORT_DATE}T00:00:00" --until "${NEXT_DATE}T00:00:00" "$NEWAPI_PROXY_NAME" >"$LOG_TMP" 2>&1 || true

traffic_stats="$(awk -v suspicious_re="$SUSPICIOUS_REGEX" '
function is_printable(s) { return (s !~ /[^[:print:]]/) }
/^[0-9A-Fa-f:.]+ / {
  total++
  ip[$1]=1
  n=split($0, q, "\"")
  if (n >= 3) {
    split(q[2], req, " ")
    path=req[2]
    split(q[3], tail, " ")
    status=tail[1]+0
    bytes=tail[2]+0
    bytes_total += bytes

    if (path ~ /^\/v1\//) gateway++
    else if (path ~ /^\/api\//) console++
    else if (path != "") web++

    if (path ~ suspicious_re) suspicious++

    if (status >= 200 && status < 300) s2++
    else if (status >= 300 && status < 400) s3++
    else if (status >= 400 && status < 500) s4++
    else if (status >= 500) s5++
  }
}
END {
  uniq=0
  for (k in ip) uniq++
  printf "%d %d %d %d %d %d %d %d %d", total+0, uniq+0, s2+0, s3+0, s4+0, s5+0, gateway+0, console+0, bytes_total+0
}
' "$LOG_TMP" || echo '0 0 0 0 0 0 0 0 0')"
read -r traffic_total traffic_ip_uniq traffic_2xx traffic_3xx traffic_4xx traffic_5xx gateway_requests console_requests response_bytes_total <<<"$traffic_stats"
web_requests=$((traffic_total - gateway_requests - console_requests))
if (( web_requests < 0 )); then
  web_requests=0
fi

suspicious_requests="$(awk -v suspicious_re="$SUSPICIOUS_REGEX" -F'"' '
/^[0-9A-Fa-f:.]+ / {
  split($2, req, " ")
  path=req[2]
  if (path ~ suspicious_re) total++
}
END { print total+0 }
' "$LOG_TMP" 2>/dev/null || echo 0)"

top_paths_raw="$(awk -F'"' '
function is_printable(s) { return (s !~ /[^[:print:]]/) }
/^[0-9A-Fa-f:.]+ / {
  split($2, req, " ")
  path=req[2]
  if (path != "" && is_printable(path)) count[path]++
}
END {
  for (k in count) print count[k] "\t" k
}
' "$LOG_TMP" | sort -nr | awk -v limit="$TOP_PATHS" 'NR<=limit')"

top_suspicious_paths_raw="$(awk -v suspicious_re="$SUSPICIOUS_REGEX" -F'"' '
function is_printable(s) { return (s !~ /[^[:print:]]/) }
/^[0-9A-Fa-f:.]+ / {
  split($2, req, " ")
  path=req[2]
  if (path != "" && is_printable(path) && path ~ suspicious_re) count[path]++
}
END {
  for (k in count) print count[k] "\t" k
}
' "$LOG_TMP" | sort -nr | awk -v limit="$TOP_SUSPICIOUS_PATHS" 'NR<=limit')"

sample_stats="$(awk -v d="$REPORT_DATE" '
$1==d {
  c++
  split($4,a,"="); load=a[2]+0; if (c==1 || load>maxload) maxload=load
  split($5,b,"="); memavail=b[2]+0; if (c==1 || memavail<minmem) minmem=memavail
  split($6,c1,"="); swap=c1[2]+0; if (c==1 || swap>maxswap) maxswap=swap
  split($7,d1,"="); nmem=d1[2]+0; if (c==1 || nmem>maxnewapi) maxnewapi=nmem
  split($8,e,"="); mmem=e[2]+0; if (c==1 || mmem>maxmysql) maxmysql=mmem
}
END {
  printf "%d %s %s %s %s %s", c+0, maxload+0, minmem+0, maxswap+0, maxnewapi+0, maxmysql+0
}
' "$NEWAPI_SAMPLE_LOG" 2>/dev/null || echo '0 0 0 0 0 0')"
read -r sample_count peak_load1 min_mem_avail peak_swap_used peak_newapi_mem peak_mysql_mem <<<"$sample_stats"

alert_total=0
if [[ -f "$NEWAPI_ALERT_LOG" ]]; then
  alert_total="$(grep -F "[$REPORT_DATE " "$NEWAPI_ALERT_LOG" 2>/dev/null | wc -l | awk '{print $1}')"
fi

fail_count="$(cat "${NEWAPI_STATE_DIR}/fail_count" 2>/dev/null || echo 0)"
last_restart_human="n/a"
if [[ -f "${NEWAPI_STATE_DIR}/last_restart_ts" ]]; then
  ts="$(cat "${NEWAPI_STATE_DIR}/last_restart_ts" 2>/dev/null || echo 0)"
  if [[ "$ts" =~ ^[0-9]+$ ]] && [[ "$ts" -gt 0 ]]; then
    last_restart_human="$(date -d "@$ts" '+%F %T' 2>/dev/null || echo n/a)"
  fi
fi

status_icon="✅"
status_text="正常"
if [[ "$current_http" == "000" || "$current_http" -ge 500 || "$alert_total" -gt 0 || "$fail_count" -gt 0 ]]; then
  status_icon="⚠️"
  status_text="需关注"
fi

msg=$(cat <<EOFMSG
${REPORT_TITLE}
总体：${status_icon} ${status_text}
主机：${REPORT_HOST}
时间：${NOW}
域名：${NEWAPI_URL}

容器状态
- $(fmt_container "$newapi_line")
- $(fmt_container "$mysql_line")
- $(fmt_container "$proxy_line")

资源与可用性
- 监控样本数：${sample_count}
- new-api 峰值内存：${peak_newapi_mem} MB ｜ mysql 峰值内存：${peak_mysql_mem} MB
- 最低可用内存：${min_mem_avail} MB ｜ swap 峰值：${peak_swap_used} MB ｜ 负载峰值：${peak_load1}
- 告警总数：${alert_total} ｜ fail_count：${fail_count} ｜ last_restart：${last_restart_human}

站点流量
- 总请求：${traffic_total} ｜ 去重 IP：${traffic_ip_uniq} ｜ 回包流量：$(compact_bytes "$response_bytes_total")
- 网关API：${gateway_requests} ｜ 控制台API：${console_requests} ｜ 页面/静态：${web_requests}
- 可疑扫描：${suspicious_requests}
- 2xx / 3xx / 4xx / 5xx：${traffic_2xx} / ${traffic_3xx} / ${traffic_4xx} / ${traffic_5xx}
Top 路径
$(format_count_path_lines "$top_paths_raw" '无路径数据')
可疑路径
$(format_count_path_lines "$top_suspicious_paths_raw" '无可疑路径')

当前资源
- HTTP：${current_http}
- MemAvailable：${current_mem_avail} MB ｜ SwapUsed：${current_swap_used} MB ｜ Load1：${current_load1}
- /：${current_disk_root}
- /opt：${current_disk_opt}
EOFMSG
)

send_notification "$msg"
log_with_ts "$NEWAPI_SYSTEM_REPORT_LOG" "sent system report for ${REPORT_DATE}"
