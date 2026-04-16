#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/../lib/common.sh"

source_newapi_manager_config
require_command rsync ssh readlink flock awk xargs

BASE="${OFFSITE_BASE_DIR}"
HOURLY="${BASE}/hourly"
DAILY="${BASE}/daily"
WEEKLY="${BASE}/weekly"
LOG_FILE="${BASE}/logs/backup.log"
LOCK_FILE="/tmp/newapi_offsite_backup.lock"

ensure_dir "$HOURLY"
ensure_dir "$DAILY"
ensure_dir "$WEEKLY"
ensure_parent_dir "$LOG_FILE"
ensure_parent_dir "$LOCK_FILE"

send_alert() {
  send_notification "$1"
}

on_fail() {
  local code="$?"
  local ts host txt
  ts="$(date '+%F %T')"
  host="$(hostname)"
  txt="[new-api异地备份失败] 时间: ${ts} 主机: ${host} 退出码: ${code} 日志: ${LOG_FILE}"
  echo "$txt" >>"$LOG_FILE"
  send_alert "$txt"
  exit "$code"
}
trap on_fail ERR

exec 9>"$LOCK_FILE"
flock -n 9 || exit 0

if [[ -z "${OFFSITE_REMOTE_HOST:-}" || -z "${OFFSITE_SSH_KEY:-}" ]]; then
  echo 'OFFSITE_REMOTE_HOST / OFFSITE_SSH_KEY is not configured' >&2
  exit 1
fi

ts_hour="$(date +"%Y-%m-%d_%H00")"
today="$(date +"%Y-%m-%d")"
week="$(date +"%G-W%V")"
dest="${HOURLY}/${ts_hour}"
latest_link="${HOURLY}/latest"
last=""
[[ -L "$latest_link" ]] && last="$(readlink -f "$latest_link" || true)"

remote_src="$(ssh -i "$OFFSITE_SSH_KEY" -o StrictHostKeyChecking=accept-new "$OFFSITE_REMOTE_HOST" "readlink -f '$OFFSITE_REMOTE_PATH'")"
remote_src="${remote_src//$'\r'/}"
if [[ -z "$remote_src" ]]; then
  echo "[$(date '+%F %T')] unable to resolve remote source: $OFFSITE_REMOTE_PATH" >>"$LOG_FILE"
  exit 1
fi

RSYNC_OPTS=(-a --delete --numeric-ids --inplace --no-compress)
if [[ -n "${last:-}" && -d "$last" ]]; then
  RSYNC_OPTS+=(--link-dest="$last")
fi

{
  echo "[$(date '+%F %T')] start hourly snapshot -> $dest"
  echo "[$(date '+%F %T')] remote source -> $OFFSITE_REMOTE_HOST:$remote_src"
  nice -n 15 ionice -c2 -n7 rsync "${RSYNC_OPTS[@]}" \
    -e "ssh -i $OFFSITE_SSH_KEY -o StrictHostKeyChecking=accept-new" \
    "$OFFSITE_REMOTE_HOST:$remote_src/" \
    "$dest/"
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

  echo "[$(date '+%F %T')] done"
} >>"$LOG_FILE" 2>&1
