# 指标口径

## 经营日报

### 真实活跃用户
- 数据源：`quota_data`
- 口径：当天在 `quota_data` 中出现过的去重 `user_id`
- 优点：比扫全量 `logs` 更轻，且能覆盖真实消耗用户

### WAU / MAU
- 数据源：`quota_data`
- 口径：
  - WAU：报表日向前 7 天内出现过的去重 `user_id`
  - MAU：报表日向前 30 天内出现过的去重 `user_id`

### 连续活跃 / 回流活跃
- 连续活跃：昨天和今天都活跃的用户
- 回流活跃：今天活跃，但昨天不活跃，且不是首次活跃的用户

### 沉默用户
- 数据源：总用户数 - 指定窗口内活跃用户数
- 可通过 `.env` 中 `BUSINESS_INACTIVE_DAYS`、`BUSINESS_LONG_INACTIVE_DAYS` 调整

### 新增活跃用户
- 数据源：`quota_data`
- 口径：某个 `user_id` 在 `quota_data` 的首次出现日期 = 报表日期

### 请求次数 / quota / tokens
- 数据源：`quota_data`
- 口径：当天 `count` / `quota` / `token_used` 汇总

### 成功营收
- 数据源：`top_ups`
- 口径：`status='success'` 且 `complete_time` 落在报表日期内的 `money` 汇总
- 说明：避免和 `subscription_orders` 双算
- 当前约定：数据库金额按 **美元（USD）** 存储，报表按 **人民币（CNY）= USD × 7** 展示
- 可通过 `.env` 中 `REVENUE_SOURCE_CURRENCY`、`REVENUE_REPORT_CURRENCY`、`REVENUE_USD_TO_CNY_RATE` 调整

### ARPPU / 客单价 / 付费率
- ARPPU：当天成功营收 / 当天付费用户数
- 客单价：当天成功营收 / 当天成功订单数
- 活跃付费率：当天付费用户 / 当天真实活跃用户
- 累计付费率：累计付费用户 / 当前总用户

### 待支付订单
- 数据源：`subscription_orders`
- 口径：`status='pending'` 且 `create_time` 落在报表日期内

### 注册增长
- 由于当前 `users` 表没有显式 `created_at` 字段，不能直接按自然日回溯注册新增
- 解决办法：每天 00:05 跑一次 `new-api-user-snapshot.sh`，保存用户快照
- 日报读取连续两天快照做差，得到：新增 / 减少 / 净增长

## 系统日报
- 数据源：Docker、`/proc/meminfo`、`free`、`df`、监控采样日志
- 主要看：容器状态、峰值内存、可用内存、swap、HTTP 可达性、自动恢复状态

### 网站流量
- 数据源：`new-api-proxy` 容器日志
- 统计项：
  - 总请求、去重 IP、回包流量
  - 网关 API 请求（`/v1/`）
  - 控制台 API 请求（`/api/`）
  - 页面/静态请求（其余可打印路径）
  - 可疑扫描请求（由 `TRAFFIC_SUSPICIOUS_REGEX` 匹配）
  - Top 路径 / Top 可疑路径
