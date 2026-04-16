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
REPORT_HOST="$(hostname)"
TOP_PATHS="${TRAFFIC_TOP_PATHS}"
TOP_SUSPICIOUS_PATHS="${TRAFFIC_TOP_SUSPICIOUS_PATHS}"
SUSPICIOUS_REGEX="${TRAFFIC_SUSPICIOUS_REGEX}"
SEND_DETAIL="${REPORT_SEND_DETAIL_MESSAGE}"

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

text_to_pre() {
  local text="$1"
  printf '<pre>%s</pre>' "$(html_escape "$text")"
}

format_count_path_block() {
  local raw="$1"
  local empty_label="$2"
  if [[ -z "$raw" ]]; then
    printf '<i>%s</i>' "$(html_escape "$empty_label")"
    return 0
  fi

  local idx=0 text="" line
  while IFS=$'\t' read -r count path; do
    [[ -n "${path:-}" ]] || continue
    idx=$((idx + 1))
    printf -v line '%d. %s | %s' "$idx" "$path" "$count"
    text+="${line}"$'\n'
  done <<<"$raw"
  text_to_pre "${text%$'\n'}"
}

container_severity() {
  local line="$1"
  local status health
  status="$(get_field "$line" 2)"
  health="$(get_field "$line" 3)"

  if [[ "$status" != "running" || "$health" == "unhealthy" || "$status" == "missing" ]]; then
    printf 'critical'
  elif [[ "$health" == "starting" ]]; then
    printf 'warning'
  else
    printf 'ok'
  fi
}

container_icon() {
  case "$(container_severity "$1")" in
    critical) printf '🔴' ;;
    warning) printf '🟡' ;;
    *) printf '🟢' ;;
  esac
}

container_compact() {
  local alias_name="$1"
  local line="$2"
  printf '%s %s' "$(container_icon "$line")" "$alias_name"
}

container_detail_line() {
  local alias_name="$1"
  local line="$2"
  printf '• %s <b>%s</b>：<code>%s</code> ｜ health <code>%s</code> ｜ restart <b>%s</b> ｜ mem <code>%s</code>' \
    "$(container_icon "$line")" \
    "$(html_escape "$alias_name")" \
    "$(html_escape "$(get_field "$line" 2)")" \
    "$(html_escape "$(get_field "$line" 3)")" \
    "$(html_escape "$(get_field "$line" 4)")" \
    "$(html_escape "$(get_field "$line" 5)")"
}

sample_value() {
  local count="$1"
  local value="$2"
  local suffix="${3:-}"
  if (( count > 0 )); then
    printf '%s%s' "$value" "$suffix"
  else
    printf 'n/a'
  fi
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

newapi_container_state="$(container_severity "$newapi_line")"
mysql_container_state="$(container_severity "$mysql_line")"
proxy_container_state="$(container_severity "$proxy_line")"

status_icon="🟢"
status_text="系统稳定"
if [[ "$current_http" == "000" || "$current_http" -ge 500 || "$newapi_container_state" == "critical" || "$mysql_container_state" == "critical" || "$proxy_container_state" == "critical" ]]; then
  status_icon="🔴"
  status_text="服务异常"
elif [[ "$alert_total" -gt 0 || "$fail_count" -gt 0 || "$current_mem_avail" -le "$MEM_AVAILABLE_MIN_MB" || "$current_swap_used" -ge "$SWAP_USED_WARN_MB" || "$traffic_5xx" -gt 0 || "$newapi_container_state" == "warning" || "$mysql_container_state" == "warning" || "$proxy_container_state" == "warning" ]]; then
  status_icon="🟡"
  status_text="需关注"
fi

summary_html=$(cat <<EOFMSG
<b>🖥️ NewAPI 系统日报</b>
<b>日期：</b><code>${REPORT_DATE}</code>
<b>总体：</b>${status_icon} <b>${status_text}</b>
<b>站点：</b><code>$(html_escape "${NEWAPI_URL}")</code>
<b>主机：</b><code>$(html_escape "${REPORT_HOST}")</code>
<b>可用性：</b>HTTP <b>${current_http}</b> ｜ fail_count <b>${fail_count}</b> ｜ 告警 <b>${alert_total}</b>
<b>容器：</b>$(container_compact 'app' "$newapi_line") ｜ $(container_compact 'db' "$mysql_line") ｜ $(container_compact 'proxy' "$proxy_line")
<b>资源：</b>MemAvail <b>${current_mem_avail}MB</b> ｜ Swap <b>${current_swap_used}MB</b> ｜ Load1 <b>${current_load1}</b>
<b>流量：</b><b>$(compact_number "$traffic_total")</b> req ｜ IP <b>${traffic_ip_uniq}</b> ｜ 5xx <b>${traffic_5xx}</b> ｜ 可疑 <b>${suspicious_requests}</b>
EOFMSG
)

detail_html=$(cat <<EOFMSG
<b>🧩 容器健康</b>
$(container_detail_line "$NEWAPI_NAME" "$newapi_line")
$(container_detail_line "$NEWAPI_MYSQL_CONTAINER" "$mysql_line")
$(container_detail_line "$NEWAPI_PROXY_NAME" "$proxy_line")

<b>📈 资源与恢复</b>
• 当前：HTTP <b>${current_http}</b> ｜ MemAvail <b>${current_mem_avail}MB</b> ｜ Swap <b>${current_swap_used}MB</b> ｜ Load1 <b>${current_load1}</b>
• 当日峰值：new-api <b>$(sample_value "$sample_count" "$peak_newapi_mem" 'MB')</b> ｜ mysql <b>$(sample_value "$sample_count" "$peak_mysql_mem" 'MB')</b>
• 当日底线：MemAvail <b>$(sample_value "$sample_count" "$min_mem_avail" 'MB')</b> ｜ Swap峰值 <b>$(sample_value "$sample_count" "$peak_swap_used" 'MB')</b> ｜ Load峰值 <b>$(sample_value "$sample_count" "$peak_load1")</b>
• 告警 <b>${alert_total}</b> ｜ fail_count <b>${fail_count}</b> ｜ 监控样本 <b>${sample_count}</b> ｜ 最近自动重启 <code>$(html_escape "$last_restart_human")</code>
• 磁盘：<code>/ $(html_escape "$current_disk_root")</code> ｜ <code>/opt $(html_escape "$current_disk_opt")</code>

<b>🌐 网站流量</b>
• 总请求：<b>$(compact_number "$traffic_total")</b> ｜ 去重 IP：<b>${traffic_ip_uniq}</b> ｜ 回包流量：<b>$(compact_bytes "$response_bytes_total")</b>
• 网关 API：<b>$(compact_number "$gateway_requests")</b> ｜ 控制台 API：<b>$(compact_number "$console_requests")</b> ｜ 页面/静态：<b>$(compact_number "$web_requests")</b>
• 状态码：<code>2xx ${traffic_2xx}</code> ｜ <code>3xx ${traffic_3xx}</code> ｜ <code>4xx ${traffic_4xx}</code> ｜ <code>5xx ${traffic_5xx}</code>
• 可疑扫描：<b>${suspicious_requests}</b>

<b>🔥 热门路径</b>
$(format_count_path_block "$top_paths_raw" '无路径数据')
<b>🛡️ 可疑路径</b>
$(format_count_path_block "$top_suspicious_paths_raw" '无可疑路径')
EOFMSG
)

send_notification_html "$summary_html"
if [[ "${SEND_DETAIL}" == "1" ]]; then
  send_notification_html "$detail_html"
fi
log_with_ts "$NEWAPI_SYSTEM_REPORT_LOG" "sent system report for ${REPORT_DATE}"
