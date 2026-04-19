# 部署说明

## 现有脚本来源
这个仓库整合了两部分脚本：

1. 新机生产脚本
   - `app_guard_monitor.sh`
   - `new-api-auto-update.sh`
   - `new-api-daily-report.sh`
2. 本地/管理机脚本
   - `new-api-db-backup.sh`
   - `backup_newapi.sh`（异地同步）

## 推荐安装位置
- 仓库代码：`/opt/newapi-manager`
- 可执行入口：`/usr/local/bin`
- 主配置文件：`/opt/newapi-manager/.env`
- 兼容配置路径：`/etc/newapi-manager.env`

## 当前 newapi 目标机
- 维护者服务器信息中的新机：`newapi-target`
- 当前主机：`104.248.222.180`
- 监控/通知脚本里的 `NEWAPI_URL` 与异地备份源建议指向这台机器，直到正式域名切换完成

## 推荐 cron
服务器侧：
- 00:05 用户快照
- 每 5 分钟健康监控
- 每小时 10 分数据库备份
- 11:00 系统日报
- 11:05 经营日报
- 每周日 03:00 自动更新

管理机侧：
- 每小时 20 分做异地备份同步

## 初次上线建议
1. 先安装但不要立刻覆盖所有 cron
2. 手动执行每个脚本一次
3. 确认 Telegram / OpenClaw 通知正常
4. 再切换 cron 到仓库版脚本

## 配置维护建议
- 平时只维护仓库根目录 `.env`
- `.env` 不提交，仓库只提交 `.env.example`
- 每次更新仓库后重新执行一次 `deploy/install.sh`，把 `.env` 同步到 `/opt/newapi-manager/.env`
