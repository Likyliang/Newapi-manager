# 指标口径

## 经营日报

### 真实活跃用户
- 数据源：`quota_data`
- 口径：当天在 `quota_data` 中出现过的去重 `user_id`
- 优点：比扫全量 `logs` 更轻，且能覆盖真实消耗用户

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
