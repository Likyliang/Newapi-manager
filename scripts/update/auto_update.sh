#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/../lib/common.sh"

source_newapi_manager_config
require_command python3 curl docker flock awk sed install

LOCK_FILE="/var/run/new-api-auto-update.lock"
BACKUP_DIR="${NEWAPI_COMPOSE_DIR}/backups"
ensure_dir "$BACKUP_DIR"
ensure_parent_dir "$NEWAPI_AUTO_UPDATE_LOG"
ensure_parent_dir "$LOCK_FILE"

get_latest_release() {
  python3 - <<'PY'
import json
import os
import urllib.request

url = os.environ['NEWAPI_RELEASES_API_URL']
req = urllib.request.Request(
    url,
    headers={
        'Accept': 'application/vnd.github+json',
        'X-GitHub-Api-Version': '2022-11-28',
        'User-Agent': 'newapi-manager-auto-update',
    },
)
with urllib.request.urlopen(req, timeout=30) as resp:
    data = json.load(resp)
print(data.get('tag_name', ''))
print(data.get('html_url', ''))
print(data.get('published_at', ''))
print('true' if not data.get('prerelease', True) and not data.get('draft', True) else 'false')
PY
}

get_current_tag() {
  if grep -q "^${NEWAPI_IMAGE_TAG_KEY}=" "$NEWAPI_ENV_FILE" 2>/dev/null; then
    awk -F= -v k="$NEWAPI_IMAGE_TAG_KEY" '$1==k{print $2; exit}' "$NEWAPI_ENV_FILE"
  else
    docker inspect -f '{{.Config.Image}}' "$NEWAPI_NAME" 2>/dev/null | awk -F: '{print $NF}'
  fi
}

set_env_tag() {
  local tag="$1"
  local tmp
  tmp="$(mktemp)"
  if grep -q "^${NEWAPI_IMAGE_TAG_KEY}=" "$NEWAPI_ENV_FILE" 2>/dev/null; then
    sed -E "s#^${NEWAPI_IMAGE_TAG_KEY}=.*#${NEWAPI_IMAGE_TAG_KEY}=${tag}#" "$NEWAPI_ENV_FILE" >"$tmp"
  else
    cat "$NEWAPI_ENV_FILE" >"$tmp"
    printf '%s=%s\n' "$NEWAPI_IMAGE_TAG_KEY" "$tag" >>"$tmp"
  fi
  install -m 600 "$tmp" "$NEWAPI_ENV_FILE"
  rm -f "$tmp"
}

wait_ready() {
  local i code
  for i in $(seq 1 36); do
    code="$(curl -k -sS -o /dev/null -w '%{http_code}' --connect-timeout 5 --max-time 15 'http://127.0.0.1:3000/api/status' || true)"
    if [[ "$code" == "200" ]]; then
      return 0
    fi
    sleep 5
  done
  return 1
}

rollback() {
  local old_tag="$1"
  set_env_tag "$old_tag"
  cd "$NEWAPI_COMPOSE_DIR"
  docker compose pull "$NEWAPI_NAME" >/dev/null 2>&1 || true
  docker compose up -d "$NEWAPI_NAME" >/dev/null 2>&1 || true
}

on_fail() {
  local code="$?"
  log_with_ts "$NEWAPI_AUTO_UPDATE_LOG" "auto-update failed with exit code ${code}"
  exit "$code"
}
trap on_fail ERR

main() {
  exec 9>"$LOCK_FILE"
  flock -n 9 || exit 0

  local latest_tag release_url published_at stable_flag current_tag now host backup_ts
  mapfile -t release_info < <(get_latest_release)
  latest_tag="${release_info[0]:-}"
  release_url="${release_info[1]:-}"
  published_at="${release_info[2]:-}"
  stable_flag="${release_info[3]:-}"
  current_tag="$(get_current_tag || true)"
  now="$(date '+%F %T')"
  host="$(hostname)"
  backup_ts="$(date +%Y%m%d-%H%M%S)"

  if [[ -z "$latest_tag" ]]; then
    send_notification "[new-api自动更新][${host}][${now}] 无法读取 GitHub 最新版本信息，已跳过。"
    log_with_ts "$NEWAPI_AUTO_UPDATE_LOG" "skip: empty latest_tag"
    exit 1
  fi

  if [[ "$stable_flag" != "true" ]]; then
    send_notification "[new-api自动更新][${host}][${now}] latest release 不是正式稳定版，已跳过：${latest_tag}。"
    log_with_ts "$NEWAPI_AUTO_UPDATE_LOG" "skip non-stable release: ${latest_tag}"
    exit 0
  fi

  [[ -n "$current_tag" ]] || current_tag="unknown"

  if [[ "$current_tag" == "$latest_tag" ]]; then
    log_with_ts "$NEWAPI_AUTO_UPDATE_LOG" "no update needed: ${current_tag}"
    exit 0
  fi

  cp -a "$NEWAPI_ENV_FILE" "$BACKUP_DIR/.env.${backup_ts}.bak"
  cp -a "$NEWAPI_COMPOSE_FILE" "$BACKUP_DIR/docker-compose.yml.${backup_ts}.bak"

  log_with_ts "$NEWAPI_AUTO_UPDATE_LOG" "update start: ${current_tag} -> ${latest_tag} (published_at=${published_at})"

  set_env_tag "$latest_tag"

  cd "$NEWAPI_COMPOSE_DIR"
  docker compose pull "$NEWAPI_NAME"
  docker compose up -d "$NEWAPI_NAME"

  if ! wait_ready; then
    rollback "$current_tag"
    send_notification "[new-api自动更新][${host}][${now}] 从 ${current_tag} 升级到 ${latest_tag} 后健康检查失败，已回滚。"
    log_with_ts "$NEWAPI_AUTO_UPDATE_LOG" "update failed and rolled back: ${current_tag} -> ${latest_tag}"
    exit 1
  fi

  send_notification "[new-api自动更新][${host}][${now}] 已从 ${current_tag} 成功更新到 ${latest_tag}。发布页：${release_url}"
  log_with_ts "$NEWAPI_AUTO_UPDATE_LOG" "update success: ${current_tag} -> ${latest_tag}"
}

main "$@"
