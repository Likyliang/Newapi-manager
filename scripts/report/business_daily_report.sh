#!/usr/bin/env bash
set -euo pipefail

SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(cd "$(dirname "${SCRIPT_PATH}")" && pwd)"
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
GROUP_TOP_N="${REPORT_GROUP_TOP_N}"
PAYMENT_METHOD_TOP_N="${REPORT_PAYMENT_METHOD_TOP_N}"
INACTIVE_DAYS="${BUSINESS_INACTIVE_DAYS}"
LONG_INACTIVE_DAYS="${BUSINESS_LONG_INACTIVE_DAYS}"

START_TS="$(date -d "${REPORT_DATE} 00:00:00" +%s)"
END_TS="$(date -d "${REPORT_DATE} +1 day 00:00:00" +%s)"
PREV_START_TS="$(date -d "${PREV_DATE} 00:00:00" +%s)"
PREV_END_TS="$(date -d "${REPORT_DATE} 00:00:00" +%s)"
WAU_START_TS="$(date -d "${REPORT_DATE} -6 day 00:00:00" +%s)"
MAU_START_TS="$(date -d "${REPORT_DATE} -29 day 00:00:00" +%s)"
MONTH_START_TS="$(date -d "$(date -d "${REPORT_DATE}" +%Y-%m-01) 00:00:00" +%s)"

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

ratio_pct() {
  awk -v a="${1:-0}" -v b="${2:-0}" 'BEGIN{ if ((b+0) == 0) printf "0.0%%"; else printf "%.1f%%", (a+0)*100/(b+0) }'
}

avg_number() {
  awk -v a="${1:-0}" -v b="${2:-0}" 'BEGIN{ if ((b+0) == 0) print 0; else printf "%.2f", (a+0)/(b+0) }'
}

nonneg_sub() {
  awk -v a="${1:-0}" -v b="${2:-0}" 'BEGIN{ v=(a+0)-(b+0); if (v<0) v=0; printf "%.0f", v }'
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

format_usage_rank_lines() {
  local raw="$1"
  local empty_label="$2"
  if [[ -z "$raw" ]]; then
    printf -- '  - %s\n' "$empty_label"
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

format_group_lines() {
  local raw="$1"
  if [[ -z "$raw" ]]; then
    printf '  - 无活跃分组数据\n'
    return 0
  fi
  local idx=0
  while IFS=$'\t' read -r group_name dau reqs quota; do
    [[ -n "${group_name:-}" ]] || continue
    idx=$((idx + 1))
    printf '  %d) %s ｜ 活跃=%s ｜ req=%s ｜ quota=%s\n' \
      "$idx" "$group_name" "$dau" "$(compact_number "$reqs")" "$(compact_number "$quota")"
  done <<<"$raw"
}

format_payment_lines() {
  local raw="$1"
  if [[ -z "$raw" ]]; then
    printf '  - 当日无成功支付\n'
    return 0
  fi
  local idx=0
  while IFS=$'\t' read -r method orders amount; do
    [[ -n "${method:-}" ]] || continue
    idx=$((idx + 1))
    printf '  %d) %s ｜ 订单=%s ｜ 营收=¥%s\n' \
      "$idx" "$method" "$orders" "$(fmt_money "$amount")"
  done <<<"$raw"
}

total_users="$(sql_scalar "SELECT COUNT(*) FROM users WHERE deleted_at IS NULL;")"
active_users="$(sql_scalar "SELECT COUNT(DISTINCT user_id) FROM quota_data WHERE created_at >= ${START_TS} AND created_at < ${END_TS} AND user_id IS NOT NULL;")"
prev_active_users="$(sql_scalar "SELECT COUNT(DISTINCT user_id) FROM quota_data WHERE created_at >= ${PREV_START_TS} AND created_at < ${PREV_END_TS} AND user_id IS NOT NULL;")"
retained_active_users="$(sql_scalar "SELECT COUNT(*) FROM (SELECT DISTINCT user_id FROM quota_data WHERE created_at >= ${START_TS} AND created_at < ${END_TS} AND user_id IS NOT NULL) t INNER JOIN (SELECT DISTINCT user_id FROM quota_data WHERE created_at >= ${PREV_START_TS} AND created_at < ${PREV_END_TS} AND user_id IS NOT NULL) y USING(user_id);")"
new_active_users="$(sql_scalar "SELECT COUNT(*) FROM (SELECT user_id FROM quota_data WHERE user_id IS NOT NULL GROUP BY user_id HAVING MIN(created_at) >= ${START_TS} AND MIN(created_at) < ${END_TS}) t;")"
wau_users="$(sql_scalar "SELECT COUNT(DISTINCT user_id) FROM quota_data WHERE created_at >= ${WAU_START_TS} AND created_at < ${END_TS} AND user_id IS NOT NULL;")"
mau_users="$(sql_scalar "SELECT COUNT(DISTINCT user_id) FROM quota_data WHERE created_at >= ${MAU_START_TS} AND created_at < ${END_TS} AND user_id IS NOT NULL;")"
request_count="$(sql_scalar "SELECT COALESCE(SUM(\`count\`),0) FROM quota_data WHERE created_at >= ${START_TS} AND created_at < ${END_TS};")"
quota_used="$(sql_scalar "SELECT COALESCE(SUM(quota),0) FROM quota_data WHERE created_at >= ${START_TS} AND created_at < ${END_TS};")"
token_used="$(sql_scalar "SELECT COALESCE(SUM(token_used),0) FROM quota_data WHERE created_at >= ${START_TS} AND created_at < ${END_TS};")"

success_revenue="$(sql_scalar "SELECT ROUND(COALESCE(SUM(money),0),2) FROM top_ups WHERE status='success' AND complete_time >= ${START_TS} AND complete_time < ${END_TS};")"
prev_success_revenue="$(sql_scalar "SELECT ROUND(COALESCE(SUM(money),0),2) FROM top_ups WHERE status='success' AND complete_time >= ${PREV_START_TS} AND complete_time < ${PREV_END_TS};")"
mtd_revenue="$(sql_scalar "SELECT ROUND(COALESCE(SUM(money),0),2) FROM top_ups WHERE status='success' AND complete_time >= ${MONTH_START_TS} AND complete_time < ${END_TS};")"
total_revenue="$(sql_scalar "SELECT ROUND(COALESCE(SUM(money),0),2) FROM top_ups WHERE status='success';")"
success_orders="$(sql_scalar "SELECT COUNT(*) FROM top_ups WHERE status='success' AND complete_time >= ${START_TS} AND complete_time < ${END_TS};")"
paying_users="$(sql_scalar "SELECT COUNT(DISTINCT user_id) FROM top_ups WHERE status='success' AND complete_time >= ${START_TS} AND complete_time < ${END_TS} AND user_id IS NOT NULL;")"
new_paying_users="$(sql_scalar "SELECT COUNT(*) FROM (SELECT user_id FROM top_ups WHERE status='success' AND user_id IS NOT NULL GROUP BY user_id HAVING MIN(complete_time) >= ${START_TS} AND MIN(complete_time) < ${END_TS}) t;")"
cumulative_paying_users="$(sql_scalar "SELECT COUNT(DISTINCT user_id) FROM top_ups WHERE status='success' AND user_id IS NOT NULL;")"
pending_orders_today="$(sql_scalar "SELECT COUNT(*) FROM subscription_orders WHERE status='pending' AND create_time >= ${START_TS} AND create_time < ${END_TS};")"
pending_amount_today="$(sql_scalar "SELECT ROUND(COALESCE(SUM(money),0),2) FROM subscription_orders WHERE status='pending' AND create_time >= ${START_TS} AND create_time < ${END_TS};")"
pending_orders_pool="$(sql_scalar "SELECT COUNT(*) FROM subscription_orders WHERE status='pending';")"
pending_amount_pool="$(sql_scalar "SELECT ROUND(COALESCE(SUM(money),0),2) FROM subscription_orders WHERE status='pending';")"

returning_active_users="$(nonneg_sub "$active_users" "$retained_active_users")"
returning_active_users="$(nonneg_sub "$returning_active_users" "$new_active_users")"
inactive_short_users="$(nonneg_sub "$total_users" "$wau_users")"
inactive_long_users="$(nonneg_sub "$total_users" "$mau_users")"
repeat_paying_users="$(nonneg_sub "$paying_users" "$new_paying_users")"
active_delta="$(signed_int_delta "$active_users" "$prev_active_users")"
revenue_delta="$(signed_float_delta "$success_revenue" "$prev_success_revenue")"
active_rate="$(ratio_pct "$active_users" "$total_users")"
cumulative_pay_rate="$(ratio_pct "$cumulative_paying_users" "$total_users")"
active_pay_rate="$(ratio_pct "$paying_users" "$active_users")"
retention_rate="$(ratio_pct "$retained_active_users" "$prev_active_users")"
avg_req_per_active="$(avg_number "$request_count" "$active_users")"
avg_quota_per_active="$(avg_number "$quota_used" "$active_users")"
avg_tokens_per_active="$(avg_number "$token_used" "$active_users")"
order_aov="$(avg_number "$success_revenue" "$success_orders")"
arppu="$(avg_number "$success_revenue" "$paying_users")"

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

top_groups_raw="$(mysql_exec "
SELECT COALESCE(NULLIF(u.\`group\`,''),'(default)') AS group_name,
       COUNT(DISTINCT q.user_id) AS dau,
       COALESCE(SUM(q.\`count\`),0) AS reqs,
       COALESCE(SUM(q.quota),0) AS quota_used
FROM quota_data q
LEFT JOIN users u ON u.id = q.user_id
WHERE q.created_at >= ${START_TS} AND q.created_at < ${END_TS}
GROUP BY group_name
ORDER BY quota_used DESC, dau DESC
LIMIT ${GROUP_TOP_N};
")"

payment_methods_raw="$(mysql_exec "
SELECT COALESCE(NULLIF(payment_method,''),'(unknown)') AS payment_method,
       COUNT(*) AS orders_cnt,
       ROUND(COALESCE(SUM(money),0),2) AS revenue
FROM top_ups
WHERE status='success' AND complete_time >= ${START_TS} AND complete_time < ${END_TS}
GROUP BY payment_method
ORDER BY revenue DESC, orders_cnt DESC
LIMIT ${PAYMENT_METHOD_TOP_N};
")"

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

msg=$(cat <<EOFMSG
new-api 经营日报（${REPORT_DATE}）
主机：${HOST}
时间：${NOW}
域名：${NEWAPI_URL}

活跃概况
- DAU：${active_users}（较前日 ${active_delta} / 活跃率 ${active_rate}）
- WAU / MAU：${wau_users} / ${mau_users}
- 连续活跃：${retained_active_users}（活跃留存 ${retention_rate}）
- 回流活跃：${returning_active_users} ｜ 新增活跃：${new_active_users}
- ${INACTIVE_DAYS}日沉默：${inactive_short_users} ｜ ${LONG_INACTIVE_DAYS}日沉默：${inactive_long_users}

使用消耗
- 请求次数：$(compact_number "$request_count")（人均 ${avg_req_per_active}）
- 消耗 quota：$(compact_number "$quota_used")（人均 $(compact_number "$avg_quota_per_active")）
- 消耗 tokens：$(compact_number "$token_used")（人均 $(compact_number "$avg_tokens_per_active")）

客户增长
- 当前总用户：${total_users_display}
${user_growth_line}
- 累计付费用户：${cumulative_paying_users}（累计付费率 ${cumulative_pay_rate}）
- 当日付费用户：${paying_users}（新增 ${new_paying_users} / 复购 ${repeat_paying_users} / 活跃付费率 ${active_pay_rate}）

营收概况
- 成功营收：¥$(fmt_money "$success_revenue")（较前日 ${revenue_delta}）
- 成功订单：${success_orders} ｜ 客单价：¥$(fmt_money "$order_aov") ｜ ARPPU：¥$(fmt_money "$arppu")
- 本月累计营收：¥$(fmt_money "$mtd_revenue") ｜ 累计总营收：¥$(fmt_money "$total_revenue")
- 今日新增待支付：${pending_orders_today} / ¥$(fmt_money "$pending_amount_today")
- 当前待支付池：${pending_orders_pool} / ¥$(fmt_money "$pending_amount_pool")

活跃分组
$(format_group_lines "$top_groups_raw")
支付方式
$(format_payment_lines "$payment_methods_raw")
Top 客户（按 quota）
$(format_usage_rank_lines "$top_users_raw" '无客户消耗数据')
Top 模型（按 quota）
$(format_usage_rank_lines "$top_models_raw" '无模型消耗数据')

口径说明
- DAU / WAU / MAU / 请求 / quota / tokens：基于 quota_data
- 注册增长：基于每日 00:05 用户快照；缺快照时显示 n/a
- 营收：基于 top_ups.success；待支付：基于 subscription_orders.pending
EOFMSG
)

send_notification "$msg"
log_with_ts "$NEWAPI_BUSINESS_REPORT_LOG" "sent business report for ${REPORT_DATE}"
