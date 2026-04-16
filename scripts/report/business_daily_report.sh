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
TOP_N="${REPORT_TOP_N}"
GROUP_TOP_N="${REPORT_GROUP_TOP_N}"
PAYMENT_METHOD_TOP_N="${REPORT_PAYMENT_METHOD_TOP_N}"
INACTIVE_DAYS="${BUSINESS_INACTIVE_DAYS}"
LONG_INACTIVE_DAYS="${BUSINESS_LONG_INACTIVE_DAYS}"
REVENUE_SOURCE="${REVENUE_SOURCE_CURRENCY}"
REVENUE_REPORT="${REVENUE_REPORT_CURRENCY}"
USD_TO_CNY_RATE="${REVENUE_USD_TO_CNY_RATE}"
SEND_DETAIL="${REPORT_SEND_DETAIL_MESSAGE}"

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

money_to_report() {
  awk -v n="${1:-0}" -v src="${REVENUE_SOURCE}" -v dst="${REVENUE_REPORT}" -v rate="${USD_TO_CNY_RATE}" '
    BEGIN {
      v=n+0
      if (src=="USD" && dst=="CNY") v=v*rate
      printf "%.2f", v
    }'
}

report_money_symbol() {
  case "${REVENUE_REPORT}" in
    CNY) printf '¥' ;;
    USD) printf '$' ;;
    *) printf '%s ' "${REVENUE_REPORT}" ;;
  esac
}

source_money_symbol() {
  case "${REVENUE_SOURCE}" in
    CNY) printf '¥' ;;
    USD) printf '$' ;;
    *) printf '%s ' "${REVENUE_SOURCE}" ;;
  esac
}

fmt_report_money() {
  printf '%s%s' "$(report_money_symbol)" "$(money_to_report "$1")"
}

fmt_source_money() {
  printf '%s%s' "$(source_money_symbol)" "$(fmt_money "$1")"
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

text_to_pre() {
  local text="$1"
  printf '<pre>%s</pre>' "$(html_escape "$text")"
}

format_usage_rank_block() {
  local raw="$1"
  local empty_label="$2"
  if [[ -z "$raw" ]]; then
    printf '<i>%s</i>' "$(html_escape "$empty_label")"
    return 0
  fi

  local idx=0 text="" line
  while IFS=$'\t' read -r name reqs quota tokens; do
    [[ -n "${name:-}" ]] || continue
    idx=$((idx + 1))
    printf -v line '%d. %s | req %s | quota %s | tok %s' \
      "$idx" "$name" "$(compact_number "$reqs")" "$(compact_number "$quota")" "$(compact_number "$tokens")"
    text+="${line}"$'\n'
  done <<<"$raw"
  text_to_pre "${text%$'\n'}"
}

format_group_block() {
  local raw="$1"
  if [[ -z "$raw" ]]; then
    printf '<i>无活跃分组数据</i>'
    return 0
  fi

  local idx=0 text="" line
  while IFS=$'\t' read -r group_name dau reqs quota; do
    [[ -n "${group_name:-}" ]] || continue
    idx=$((idx + 1))
    printf -v line '%d. %s | dau %s | req %s | quota %s' \
      "$idx" "$group_name" "$dau" "$(compact_number "$reqs")" "$(compact_number "$quota")"
    text+="${line}"$'\n'
  done <<<"$raw"
  text_to_pre "${text%$'\n'}"
}

format_payment_block() {
  local raw="$1"
  if [[ -z "$raw" ]]; then
    printf '<i>当日无成功套餐支付</i>'
    return 0
  fi

  local idx=0 text="" line
  while IFS=$'\t' read -r method orders amount; do
    [[ -n "${method:-}" ]] || continue
    idx=$((idx + 1))
    printf -v line '%d. %s | orders %s | revenue %s' \
      "$idx" "$method" "$orders" "$(fmt_report_money "$amount")"
    text+="${line}"$'\n'
  done <<<"$raw"
  text_to_pre "${text%$'\n'}"
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

success_revenue="$(sql_scalar "SELECT ROUND(COALESCE(SUM(money),0),2) FROM subscription_orders WHERE status='success' AND complete_time >= ${START_TS} AND complete_time < ${END_TS};")"
prev_success_revenue="$(sql_scalar "SELECT ROUND(COALESCE(SUM(money),0),2) FROM subscription_orders WHERE status='success' AND complete_time >= ${PREV_START_TS} AND complete_time < ${PREV_END_TS};")"
mtd_revenue="$(sql_scalar "SELECT ROUND(COALESCE(SUM(money),0),2) FROM subscription_orders WHERE status='success' AND complete_time >= ${MONTH_START_TS} AND complete_time < ${END_TS};")"
total_revenue="$(sql_scalar "SELECT ROUND(COALESCE(SUM(money),0),2) FROM subscription_orders WHERE status='success';")"
success_orders="$(sql_scalar "SELECT COUNT(*) FROM subscription_orders WHERE status='success' AND complete_time >= ${START_TS} AND complete_time < ${END_TS};")"
paying_users="$(sql_scalar "SELECT COUNT(DISTINCT user_id) FROM subscription_orders WHERE status='success' AND complete_time >= ${START_TS} AND complete_time < ${END_TS} AND user_id IS NOT NULL;")"
new_paying_users="$(sql_scalar "SELECT COUNT(*) FROM (SELECT user_id FROM subscription_orders WHERE status='success' AND user_id IS NOT NULL GROUP BY user_id HAVING MIN(complete_time) >= ${START_TS} AND MIN(complete_time) < ${END_TS}) t;")"
cumulative_paying_users="$(sql_scalar "SELECT COUNT(DISTINCT user_id) FROM subscription_orders WHERE status='success' AND user_id IS NOT NULL;")"
pending_orders_today="$(sql_scalar "SELECT COUNT(*) FROM subscription_orders WHERE status='pending' AND create_time >= ${START_TS} AND create_time < ${END_TS};")"
pending_amount_today="$(sql_scalar "SELECT ROUND(COALESCE(SUM(money),0),2) FROM subscription_orders WHERE status='pending' AND create_time >= ${START_TS} AND create_time < ${END_TS};")"

returning_active_users="$(nonneg_sub "$active_users" "$retained_active_users")"
returning_active_users="$(nonneg_sub "$returning_active_users" "$new_active_users")"
inactive_short_users="$(nonneg_sub "$total_users" "$wau_users")"
inactive_long_users="$(nonneg_sub "$total_users" "$mau_users")"
repeat_paying_users="$(nonneg_sub "$paying_users" "$new_paying_users")"
active_delta="$(signed_int_delta "$active_users" "$prev_active_users")"
active_rate="$(ratio_pct "$active_users" "$total_users")"
cumulative_pay_rate="$(ratio_pct "$cumulative_paying_users" "$total_users")"
active_pay_rate="$(ratio_pct "$paying_users" "$active_users")"
retention_rate="$(ratio_pct "$retained_active_users" "$prev_active_users")"
avg_req_per_active="$(avg_number "$request_count" "$active_users")"
avg_quota_per_active="$(avg_number "$quota_used" "$active_users")"
avg_tokens_per_active="$(avg_number "$token_used" "$active_users")"
order_aov="$(avg_number "$success_revenue" "$success_orders")"
arppu="$(avg_number "$success_revenue" "$paying_users")"
success_revenue_report="$(money_to_report "$success_revenue")"
prev_success_revenue_report="$(money_to_report "$prev_success_revenue")"
mtd_revenue_report="$(money_to_report "$mtd_revenue")"
total_revenue_report="$(money_to_report "$total_revenue")"
pending_amount_today_report="$(money_to_report "$pending_amount_today")"
order_aov_report="$(money_to_report "$order_aov")"
arppu_report="$(money_to_report "$arppu")"
revenue_delta_report="$(signed_float_delta "$success_revenue_report" "$prev_success_revenue_report")"

IFS='|' read -r snapshot_start_users snapshot_end_users snapshot_added snapshot_removed <<<"$(snapshot_growth_summary)"
if [[ "$snapshot_added" == "n/a" ]]; then
  user_growth_text="注册增长：暂缺快照（建议启用 00:05 用户快照任务）"
  total_users_display="$total_users"
else
  net_growth=$((snapshot_added - snapshot_removed))
  total_users_display="$snapshot_end_users"
  if [[ "$net_growth" -ge 0 ]]; then
    user_growth_text="注册增长：净 +${net_growth}（新增 ${snapshot_added} / 减少 ${snapshot_removed} / 期末总用户 ${snapshot_end_users}）"
  else
    user_growth_text="注册增长：净 ${net_growth}（新增 ${snapshot_added} / 减少 ${snapshot_removed} / 期末总用户 ${snapshot_end_users}）"
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
FROM subscription_orders
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

if (( active_users == 0 )); then
  status_icon="🔴"
  status_text="无真实活跃"
elif [[ "$active_delta" == -* ]]; then
  status_icon="🟡"
  status_text="活跃波动"
else
  status_icon="🟢"
  status_text="运营稳定"
fi

summary_html=$(cat <<EOFMSG
<b>📊 NewAPI 经营日报</b>
<b>日期：</b><code>${REPORT_DATE}</code>
<b>总体：</b>${status_icon} <b>${status_text}</b>
<b>营收：</b><b>$(fmt_report_money "$success_revenue")</b>（原始 $(fmt_source_money "$success_revenue")）
<b>活跃：</b><b>DAU ${active_users}</b>（${active_rate}）｜ WAU/MAU ${wau_users}/${mau_users}
<b>客户：</b>总用户 <b>${total_users_display}</b> ｜ 累计付费 <b>${cumulative_paying_users}</b>
<b>新增：</b>活跃 <b>${new_active_users}</b> ｜ 付费 <b>${new_paying_users}</b>
<b>待支付：</b>${pending_orders_today} 单 / $(report_money_symbol)${pending_amount_today_report}
<i>营收仅统计真实套餐支付，不含兑换码</i>
EOFMSG
)

detail_html=$(cat <<EOFMSG
<b>👥 活跃与增长</b>
• 连续活跃：<b>${retained_active_users}</b>（留存 ${retention_rate}）
• 回流活跃：<b>${returning_active_users}</b> ｜ 新增活跃：<b>${new_active_users}</b>
• ${INACTIVE_DAYS}日沉默：<b>${inactive_short_users}</b> ｜ ${LONG_INACTIVE_DAYS}日沉默：<b>${inactive_long_users}</b>
• $(html_escape "$user_growth_text")
• 累计付费率：<b>${cumulative_pay_rate}</b> ｜ 活跃付费率：<b>${active_pay_rate}</b>

<b>⚙️ 使用消耗</b>
• 请求次数：<b>$(compact_number "$request_count")</b>（人均 ${avg_req_per_active}）
• Quota：<b>$(compact_number "$quota_used")</b>（人均 $(compact_number "$avg_quota_per_active")）
• Tokens：<b>$(compact_number "$token_used")</b>（人均 $(compact_number "$avg_tokens_per_active")）

<b>💰 营收与付费</b>
• 成功订单：<b>${success_orders}</b> ｜ 客单价：<b>$(report_money_symbol)${order_aov_report}</b> ｜ ARPPU：<b>$(report_money_symbol)${arppu_report}</b>
• 本月累计营收：<b>$(report_money_symbol)${mtd_revenue_report}</b>
• 累计总营收：<b>$(report_money_symbol)${total_revenue_report}</b>
• 今日新增待支付：<b>${pending_orders_today}</b> / <b>$(report_money_symbol)${pending_amount_today_report}</b>

<b>🏷️ 活跃分组</b>
$(format_group_block "$top_groups_raw")
<b>💳 套餐支付方式</b>
$(format_payment_block "$payment_methods_raw")
<b>⭐ Top 客户（按 quota）</b>
$(format_usage_rank_block "$top_users_raw" '无客户消耗数据')
<b>🤖 Top 模型（按 quota）</b>
$(format_usage_rank_block "$top_models_raw" '无模型消耗数据')

<code>口径：金额按 ${REVENUE_SOURCE} 存储，按 ${REVENUE_REPORT} 展示，汇率 ${USD_TO_CNY_RATE}</code>
EOFMSG
)

send_notification_html "$summary_html"
if [[ "${SEND_DETAIL}" == "1" ]]; then
  send_notification_html "$detail_html"
fi
log_with_ts "$NEWAPI_BUSINESS_REPORT_LOG" "sent business report for ${REPORT_DATE}"
