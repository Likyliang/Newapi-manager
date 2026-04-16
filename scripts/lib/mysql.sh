#!/usr/bin/env bash
# shellcheck shell=bash

SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(cd "$(dirname "${SCRIPT_PATH}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/common.sh"

load_newapi_db_env() {
  if [[ -f "$NEWAPI_ENV_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$NEWAPI_ENV_FILE"
  fi
  : "${MYSQL_ROOT_PASSWORD:=}"
  : "${MYSQL_USER:=}"
  : "${MYSQL_PASSWORD:=}"
}

mysql_exec() {
  local sql="$1"
  load_newapi_db_env
  if [[ -z "$MYSQL_ROOT_PASSWORD" ]]; then
    printf 'MYSQL_ROOT_PASSWORD is empty; check %s\n' "$NEWAPI_ENV_FILE" >&2
    return 1
  fi
  docker exec \
    -e MYSQL_PWD="$MYSQL_ROOT_PASSWORD" \
    "$NEWAPI_MYSQL_CONTAINER" \
    mysql --default-character-set=utf8mb4 -uroot -N -B "$NEWAPI_DB_NAME" -e "$sql"
}

mysql_file() {
  local sql_file="$1"
  load_newapi_db_env
  docker exec \
    -i \
    -e MYSQL_PWD="$MYSQL_ROOT_PASSWORD" \
    "$NEWAPI_MYSQL_CONTAINER" \
    mysql --default-character-set=utf8mb4 -uroot -N -B "$NEWAPI_DB_NAME" <"$sql_file"
}
