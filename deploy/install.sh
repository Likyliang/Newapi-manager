#!/usr/bin/env bash
set -euo pipefail

SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
REPO_ROOT="$(cd "$(dirname "${SCRIPT_PATH}")/.." && pwd)"
INSTALL_ROOT="${INSTALL_ROOT:-/opt/newapi-manager}"
BIN_DIR="${BIN_DIR:-/usr/local/bin}"
CRON_DIR="${CRON_DIR:-/etc/cron.d}"
CONFIG_PATH="${CONFIG_PATH:-/etc/newapi-manager.env}"
INSTALL_SERVER_CRON="${INSTALL_SERVER_CRON:-1}"
REPO_ENV="${REPO_ROOT}/.env"
REPO_ENV_EXAMPLE="${REPO_ROOT}/.env.example"
INSTALL_ENV="${INSTALL_ROOT}/.env"

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    echo 'please run as root' >&2
    exit 1
  fi
}

link_script() {
  local source_path="$1"
  local target_name="$2"
  ln -sfn "$source_path" "${BIN_DIR}/${target_name}"
}

require_root
mkdir -p "$INSTALL_ROOT" "$BIN_DIR"
rsync -a --delete \
  "$REPO_ROOT/scripts/" "$INSTALL_ROOT/scripts/"
install -d "$INSTALL_ROOT/config/examples" "$INSTALL_ROOT/config/cron/server" "$INSTALL_ROOT/config/cron/manager-host" "$INSTALL_ROOT/docs"
rsync -a --delete "$REPO_ROOT/config/examples/" "$INSTALL_ROOT/config/examples/"
rsync -a --delete "$REPO_ROOT/config/cron/server/" "$INSTALL_ROOT/config/cron/server/"
rsync -a --delete "$REPO_ROOT/config/cron/manager-host/" "$INSTALL_ROOT/config/cron/manager-host/"
rsync -a --delete "$REPO_ROOT/docs/" "$INSTALL_ROOT/docs/"
install -m 644 "$REPO_ROOT/README.md" "$INSTALL_ROOT/README.md"
install -m 644 "$REPO_ENV_EXAMPLE" "$INSTALL_ROOT/.env.example"

link_script "$INSTALL_ROOT/scripts/monitor/guard.sh" app_guard_monitor.sh
ln -sfn "$BIN_DIR/app_guard_monitor.sh" "$BIN_DIR/new-api-guard.sh"
link_script "$INSTALL_ROOT/scripts/update/auto_update.sh" new-api-auto-update.sh
link_script "$INSTALL_ROOT/scripts/report/system_daily_report.sh" new-api-daily-report.sh
link_script "$INSTALL_ROOT/scripts/report/business_daily_report.sh" new-api-business-report.sh
link_script "$INSTALL_ROOT/scripts/report/user_snapshot.sh" new-api-user-snapshot.sh
link_script "$INSTALL_ROOT/scripts/backup/db_backup.sh" new-api-db-backup.sh
link_script "$INSTALL_ROOT/scripts/backup/offsite_backup.sh" new-api-offsite-backup.sh

if [[ -f "$REPO_ENV" ]]; then
  install -m 600 "$REPO_ENV" "$INSTALL_ENV"
fi

if [[ ! -f "$CONFIG_PATH" && ! -L "$CONFIG_PATH" ]]; then
  install -m 600 "$REPO_ROOT/config/examples/newapi-manager.env.example" "$CONFIG_PATH"
fi

if [[ "$INSTALL_SERVER_CRON" == "1" ]]; then
  install -m 644 "$REPO_ROOT/config/cron/server/new-api-guard" "$CRON_DIR/new-api-guard"
  install -m 644 "$REPO_ROOT/config/cron/server/new-api-auto-update" "$CRON_DIR/new-api-auto-update"
  install -m 644 "$REPO_ROOT/config/cron/server/new-api-daily-report" "$CRON_DIR/new-api-daily-report"
  install -m 644 "$REPO_ROOT/config/cron/server/new-api-business-report" "$CRON_DIR/new-api-business-report"
  install -m 644 "$REPO_ROOT/config/cron/server/new-api-user-snapshot" "$CRON_DIR/new-api-user-snapshot"
  install -m 644 "$REPO_ROOT/config/cron/server/new-api-db-backup" "$CRON_DIR/new-api-db-backup"
fi

cat <<SUMMARY
Installed newapi-manager to: $INSTALL_ROOT
Config file: $CONFIG_PATH
Primary repo env: $INSTALL_ENV
Bin dir: $BIN_DIR
Cron dir: $CRON_DIR

Next steps:
1. Prefer editing $INSTALL_ENV (or repo root .env before reinstall); scripts will优先读取 .env
2. Ensure $INSTALL_ROOT/scripts have execute permission
3. Test each script manually before relying on cron
4. For offsite backup, separately install config/cron/manager-host/new-api-offsite-backup.crontab on your backup host
SUMMARY
