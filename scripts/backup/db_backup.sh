#!/usr/bin/env bash
set -euo pipefail

SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(cd "$(dirname "${SCRIPT_PATH}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/../lib/common.sh"

source_newapi_manager_config
require_command docker rsync flock gzip awk install

BASE="${NEWAPI_DB_BACKUP_BASE}"
HOURLY="${BASE}/hourly"
DAILY="${BASE}/daily"
WEEKLY="${BASE}/weekly"
LOCK_FILE="/var/run/new-api-db-backup.lock"
MYSQL_CONTAINER="${NEWAPI_MYSQL_CONTAINER}"

ensure_dir "$HOURLY"
ensure_dir "$DAILY"
ensure_dir "$WEEKLY"
ensure_parent_dir "$NEWAPI_DB_BACKUP_LOG"
ensure_parent_dir "$LOCK_FILE"

if [[ -f "$NEWAPI_ENV_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$NEWAPI_ENV_FILE"
fi
: "${MYSQL_ROOT_PASSWORD:=}"

send_alert() {
  send_notification "$1"
}

on_fail() {
  local code="$?"
  local ts host txt
  ts="$(date '+%F %T')"
  host="$(hostname)"
  txt="[new-api数据库备份失败] 时间: ${ts} 主机: ${host} 退出码: ${code} 日志: ${NEWAPI_DB_BACKUP_LOG}"
  echo "$txt" >>"$NEWAPI_DB_BACKUP_LOG"
  send_alert "$txt"
  exit "$code"
}
trap on_fail ERR

exec 9>"$LOCK_FILE"
flock -n 9 || exit 0

if [[ -z "$MYSQL_ROOT_PASSWORD" ]]; then
  echo "MYSQL_ROOT_PASSWORD is empty; check ${NEWAPI_ENV_FILE}" >&2
  exit 1
fi

ts_hour="$(date +"%Y-%m-%d_%H00")"
today="$(date +"%Y-%m-%d")"
week="$(date +"%G-W%V")"
dest="${HOURLY}/${ts_hour}"
latest_link="${HOURLY}/latest"
last=""
[[ -L "$latest_link" ]] && last="$(readlink -f "$latest_link" || true)"

mkdir -p "$dest" "$dest/config" "$dest/data" "$dest/mysql" "$dest/branding"

TMP_CNF="$(mktemp)"
cleanup() {
  rm -f "$TMP_CNF" || true
  docker exec "$MYSQL_CONTAINER" rm -f /tmp/newapi-mysqldump.cnf >/dev/null 2>&1 || true
}
trap cleanup EXIT

cat >"$TMP_CNF" <<EOF2
[client]
user=root
password=${MYSQL_ROOT_PASSWORD}
EOF2

docker cp "$TMP_CNF" "$MYSQL_CONTAINER":/tmp/newapi-mysqldump.cnf >/dev/null
cd "$NEWAPI_COMPOSE_DIR"
docker compose -f "$NEWAPI_COMPOSE_FILE" exec -T mysql \
  /usr/bin/mysqldump \
  --defaults-extra-file=/tmp/newapi-mysqldump.cnf \
  --single-transaction \
  --quick \
  --routines \
  --events \
  --triggers \
  --default-character-set=utf8mb4 \
  "$NEWAPI_DB_NAME" | gzip -c >"$dest/mysql/${NEWAPI_DB_NAME}.sql.gz"

RSYNC_OPTS=(-a --delete --numeric-ids --inplace --no-compress)
if [[ -n "${last:-}" && -d "$last/data" ]]; then
  RSYNC_OPTS+=(--link-dest="$last/data")
fi
nice -n 15 ionice -c2 -n7 rsync "${RSYNC_OPTS[@]}" "$NEWAPI_DATA_DIR/" "$dest/data/"

if [[ -d "$NEWAPI_BRANDING_DIR" ]]; then
  rsync -a --delete "$NEWAPI_BRANDING_DIR/" "$dest/branding/"
fi
cp -a "$NEWAPI_COMPOSE_FILE" "$dest/config/docker-compose.yml"
cp -a "$NEWAPI_ENV_FILE" "$dest/config/.env"
[[ -f "$NEWAPI_NGINX_CONF" ]] && cp -a "$NEWAPI_NGINX_CONF" "$dest/config/default.conf"

ln -sfn "$dest" "$latest_link"

if [[ "$(date +%H)" == "00" ]]; then
  [[ -e "$DAILY/$today" ]] || cp -al "$dest" "$DAILY/$today"
fi
if [[ "$(date +%u)" == "1" && "$(date +%H)" == "00" ]]; then
  [[ -e "$WEEKLY/$week" ]] || cp -al "$dest" "$WEEKLY/$week"
fi

find "$HOURLY" -mindepth 1 -maxdepth 1 -type d -name '20*' -printf '%T@ %p\n' | sort -nr | awk 'NR>48{print $2}' | xargs -r rm -rf
find "$DAILY" -mindepth 1 -maxdepth 1 -type d -name '20*' -printf '%T@ %p\n' | sort -nr | awk 'NR>7{print $2}' | xargs -r rm -rf
find "$WEEKLY" -mindepth 1 -maxdepth 1 -type d -printf '%T@ %p\n' | sort -nr | awk 'NR>4{print $2}' | xargs -r rm -rf

log_with_ts "$NEWAPI_DB_BACKUP_LOG" "snapshot -> $dest"
