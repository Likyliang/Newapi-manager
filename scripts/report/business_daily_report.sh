#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/../lib/common.sh"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/../lib/mysql.sh"

source_newapi_manager_config
require_command docker awk date sort comm wc head

REPORT_DATE="${1:-$(date -d 'yesterday' +%F)}"
PREV_DATE="$(date -d "${REPORT_DATE} -1 day" +%F)"
NEXT_DATE="$(date -d "${REPORT_DATE} +1 day" +%F)"
NOW="$(date '+%F %T')"
HOST="$(hostname)"
TOP_N="${REPORT_TOP_N}"

START_TS="$(date -d "${REPORT_DATE} 00:00:00" +%s)"
END_TS="$(date -d "${REPORT_DATE} +1 day 00:00:00" +%s)"
PREV_START_TS="$(date -d "${PREV_DATE} 00:00:00" +%s)"
PREV_END_TS="$(date -d "${REPORT_DATE} 00:00:00" +%s)"

sql_scalar() {
  local sql="$1"
  mysql_exec "$sql" | head -n 1 | tr -d '\r'
}

signed_int_delta() {
  awk -v a="${1:-0}" -v b="${2:-0}" 'BEGIN{printf "%+d", (a+0)-(b+0)}'
}

signed_float_delta() {
  awk -v a="${1:-0}" -v b="${2:-0}" 'BEGIN{printf "%+.2f", (a+0)-(b+0)}'
}

fmt_money() {
  awk -v n="${1:-0}" 'BEGIN{printf "%.2f", n+0}'
}

snapshot_growth_summary() {
  local start_file="${NEWAPI_USER_SNAPSHOT_DIR}/${REPORT_DATE}.tsv"
  local end_file="${NEWAPI_USER_SNAPSHOT_DIR}/${NEXT_DATE}.tsv"
  if [[ ! -f "$start_file" || ! -f "$end_file" ]]; then
    printf 'n/a|n/a|n/a|n/a\n'
    return 0
  fi

  local start_ids end_ids added removed start_count end_count
  start_ids="$(mktemp)"
  end_ids="$(mktemp)"
  trap 'rm -f "$start_ids" "$end_ids"' RETURN

  cut -f1 "$start_file" | sort -n >"$start_ids"
  cut -f1 "$end_file" | sort -n >"$end_ids"

  start_count="$(wc -l <"$start_ids" | awk '{print $1}')"
  end_count="$(wc -l <"$end_ids" | awk '{print $1}')"
  added="$(comm -13 "$start_ids" "$end_ids" | wc -l | awk '{print $1}')"
  removed="$(comm -23 "$start_ids" "$end_ids" | wc -l | awk '{print $1}')"
  printf '%s|%s|%s|%s\n' "$start_count" "$end_count" "$added" "$removed"
}

total_users="$(sql_scalar "SELECT COUNT(*) FROM users WHERE deleted_at IS NULL;")"
active_users="$(sql_scalar "SELECT COUNT(DISTINCT user_id) FROM quota_data WHERE created_at >= ${START_TS} AND created_at < ${END_TS} AND user_id IS NOT NULL;")"
prev_active_users="$(sql_scalar "SELECT COUNT(DISTINCT user_id) FROM quota_data WHERE created_at >= ${PREV_START_TS} AND created_at < ${PREV_END_TS} AND user_id IS NOT NULL;")"
new_active_users="$(sql_scalar "SELECT COUNT(*) FROM (SELECT user_id FROM quota_data WHERE user_id IS NOT NULL GROUP BY user_id HAVING MIN(created_at) >= ${START_TS} AND MIN(created_at) < ${END_TS}) t;")"
request_count="$(sql_scalar "SELECT COALESCE(SUM(count),0) FROM quota_data WHERE created_at >= ${START_TS} AND created_at < ${END_TS};")"
quota_used="$(sql_scalar "SELECT COALESCE(SUM(quota),0) FROM quota_data WHERE created_at >= ${START_TS} AND created_at < ${END_TS};")"
token_used="$(sql_scalar "SELECT COALESCE(SUM(token_used),0) FROM quota_data WHERE created_at >= ${START_TS} AND created_at < ${END_TS};")"

success_revenue="$(sql_scalar "SELECT ROUND(COALESCE(SUM(money),0),2) FROM top_ups WHERE status='success' AND complete_time >= ${START_TS} AND complete_time < ${END_TS};")"
prev_success_revenue="$(sql_scalar "SELECT ROUND(COALESCE(SUM(money),0),2) FROM top_ups WHERE status='success' AND complete_time >= ${PREV_START_TS} AND complete_time < ${PREV_END_TS};")"
success_orders="$(sql_scalar "SELECT COUNT(*) FROM top_ups WHERE status='success' AND complete_time >= ${START_TS} AND complete_time < ${END_TS};")"
paying_users="$(sql_scalar "SELECT COUNT(DISTINCT user_id) FROM top_ups WHERE status='success' AND complete_time >= ${START_TS} AND complete_time < ${END_TS} AND user_id IS NOT NULL;")"
new_paying_users="$(sql_scalar "SELECT COUNT(*) FROM (SELECT user_id FROM top_ups WHERE status='success' AND user_id IS NOT NULL GROUP BY user_id HAVING MIN(complete_time) >= ${START_TS} AND MIN(complete_time) < ${END_TS}) t;")"
cumulative_paying_users="$(sql_scalar "SELECT COUNT(DISTINCT user_id) FROM top_ups WHERE status='success' AND user_id IS NOT NULL;")"
pending_orders="$(sql_scalar "SELECT COUNT(*) FROM subscription_orders WHERE status='pending' AND create_time >= ${START_TS} AND create_time < ${END_TS};")"
pending_amount="$(sql_scalar "SELECT ROUND(COALESCE(SUM(money),0),2) FROM subscription_orders WHERE status='pending' AND create_time >= ${START_TS} AND create_time < ${END_TS};")"

repeat_paying_users="$(awk -v a="$paying_users" -v b="$new_paying_users" 'BEGIN{v=(a+0)-(b+0); if (v<0) v=0; print v}')"
active_delta="$(signed_int_delta "$active_users" "$prev_active_users")"
revenue_delta="$(signed_float_delta "$success_revenue" "$prev_success_revenue")"

IFS='|' read -r snapshot_start_users snapshot_end_users snapshot_added snapshot_removed <<<"$(snapshot_growth_summary)"
if [[ "$snapshot_added" == "n/a" ]]; then
  user_growth_line="- 注册增长：暂缺快照（建议启用 00:05 用户快照任务）"
  total_users_display="$total_users"
else
  net_growth=$((snapshot_added - snapshot_removed))
  total_users_display="$snapshot_end_users"
  if [[ "$net_growth" -ge 0 ]]; then
    user_growth_line="- 注册增长：净 +${net_growth}（新增 ${snapshot_added} / 减少 ${snapshot_removed} / 期末总用户 ${snapshot_end_users}）"
  else
    user_growth_line="- 注册增长：净 ${net_growth}（新增 ${snapshot_added} / 减少 ${snapshot_removed} / 期末总用户 ${snapshot_end_users}）"
  fi
fi

top_users_raw="$(mysql_exec "
SELECT COALESCE(NULLIF(username,''), CONCAT('uid=', user_id)) AS user_name,
       COALESCE(SUM(\`count\`),0) AS reqs,
       COALESCE(SUM(quota),0) AS quota_used,
       COALESCE(SUM(token_used),0) AS token_used
FROM quota_data
WHERE created_at >= ${START_TS} AND created_at < ${END_TS}
GROUP BY user_id, username
ORDER BY quota_used DESC, reqs DESC
LIMIT ${TOP_N};
")"

top_models_raw="$(mysql_exec "
SELECT COALESCE(NULLIF(model_name,''), '(unknown)') AS model_name,
       COALESCE(SUM(\`count\`),0) AS reqs,
       COALESCE(SUM(quota),0) AS quota_used,
       COALESCE(SUM(token_used),0) AS token_used
FROM quota_data
WHERE created_at >= ${START_TS} AND created_at < ${END_TS}
GROUP BY model_name
ORDER BY quota_used DESC, reqs DESC
LIMIT ${TOP_N};
")"

format_rank_lines() {
  local raw="$1"
  local label="$2"
  if [[ -z "$raw" ]]; then
    printf -- '- %s：无数据\n' "$label"
    return 0
  fi
  local idx=0
  while IFS=$'\t' read -r name reqs quota tokens; do
    [[ -n "${name:-}" ]] || continue
    idx=$((idx + 1))
    printf '  %d) %s ｜ req=%s ｜ quota=%s ｜ tokens=%s\n' \
      "$idx" "$name" "$(compact_number "$reqs")" "$(compact_number "$quota")" "$(compact_number "$tokens")"
  done <<<"$raw"
}

msg=$(cat <<EOFMSG
new-api 经营日报（${REPORT_DATE}）
主机：${HOST}
时间：${NOW}
域名：${NEWAPI_URL}

核心指标
- 真实活跃用户：${active_users}（较前日 ${active_delta}）
- 新增活跃用户：${new_active_users}
- 请求次数：$(compact_number "$request_count")
- 消耗 quota：$(compact_number "$quota_used")
- 消耗 tokens：$(compact_number "$token_used")

客户与营收
- 当前总用户：${total_users_display}
${user_growth_line}
- 新增付费用户：${new_paying_users}
- 当日付费用户：${paying_users}（复购 ${repeat_paying_users}）
- 累计付费用户：${cumulative_paying_users}
- 成功订单：${success_orders}
- 成功营收：¥$(fmt_money "$success_revenue")（较前日 ${revenue_delta}）
- 待支付订单：${pending_orders} / ¥$(fmt_money "$pending_amount")

Top 客户（按 quota）
$(format_rank_lines "$top_users_raw" '客户')
Top 模型（按 quota）
$(format_rank_lines "$top_models_raw" '模型')

口径说明
- 真实活跃用户 / 请求 / quota / tokens：基于 quota_data 聚合表
- 注册增长：基于每日 00:05 用户快照；未启用前显示 n/a
- 营收：基于 top_ups.success；待支付基于 subscription_orders.pending
EOFMSG
)

send_notification "$msg"
log_with_ts "$NEWAPI_BUSINESS_REPORT_LOG" "sent business report for ${REPORT_DATE}"
