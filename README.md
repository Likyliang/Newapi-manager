# Newapi-manager

一个把 `new-api` 运维脚本、备份脚本、监控脚本、日报脚本统一纳入版本管理的仓库。

## 当前已整理能力

- 健康监控与自动恢复
- 自动更新与失败回滚
- 本机数据库/配置/品牌资源备份
- 管理机异地备份同步
- 系统日报（资源 / 容器 / 可用性）
- 经营日报（活跃 / 增长 / 营收 / Top 客户 / Top 模型）
- 用户快照（解决 `users` 表无 `created_at` 无法精确算注册增长的问题）

## 目录结构

```text
scripts/
  lib/
  monitor/
  update/
  backup/
  report/
config/
  examples/
  cron/
deploy/
docs/
```

## 脚本入口

| 入口 | 作用 |
| --- | --- |
| `scripts/monitor/guard.sh` | 健康探测、资源阈值告警、自动恢复 |
| `scripts/update/auto_update.sh` | new-api 自动更新与回滚 |
| `scripts/backup/db_backup.sh` | 本机 hourly/daily/weekly 备份 |
| `scripts/backup/offsite_backup.sh` | 管理机拉取远端最新备份做异地保留 |
| `scripts/report/system_daily_report.sh` | 系统日报 |
| `scripts/report/business_daily_report.sh` | 经营日报 |
| `scripts/report/user_snapshot.sh` | 用户快照 |

## 快速开始

1. 复制配置样板
   - `cp .env.example .env`
2. 按实际环境填写域名、容器名、数据库 env、通知方式
3. 运行安装器
   - `sudo bash deploy/install.sh`
4. 手动测试脚本
5. 再启用 cron

## 配置文件约定

- 仓库根目录 `.env`：**推荐唯一维护入口**
- `.env.example`：提交到 Git，用作模板
- `.env` 已被 `.gitignore` 忽略，不会推送敏感信息
- 安装后脚本会优先读取：
  1. `NEWAPI_MANAGER_CONFIG`
  2. 仓库/安装目录下的 `.env`
  3. `/etc/newapi-manager.env`
  4. 旧路径兼容：`/etc/new-api-monitor.env`、`/etc/app-guard.env`

## 推荐先手测的命令

```bash
/usr/bin/env NEWAPI_MANAGER_STDOUT_ONLY=1 /usr/local/bin/new-api-business-report.sh 2026-04-15
/usr/bin/env NEWAPI_MANAGER_STDOUT_ONLY=1 /usr/local/bin/new-api-daily-report.sh 2026-04-15
/usr/local/bin/app_guard_monitor.sh
/usr/local/bin/new-api-user-snapshot.sh
/usr/local/bin/new-api-db-backup.sh
```

## 说明

- 指标口径见：`docs/metrics-definition.md`
- 部署建议见：`docs/deployment-notes.md`
- 当前仓库优先沉淀“脚本与配置管理”；后续可以再补 Web 面板 / CLI 子命令封装
