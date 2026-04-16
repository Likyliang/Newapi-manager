#!/usr/bin/env bash
set -euo pipefail

SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(cd "$(dirname "${SCRIPT_PATH}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/../lib/common.sh"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/../lib/mysql.sh"

source_newapi_manager_config
require_command docker awk sort flock

LOCK_FILE="/var/run/new-api-user-snapshot.lock"
SNAPSHOT_DIR="${NEWAPI_USER_SNAPSHOT_DIR}"
SNAPSHOT_DATE="${1:-$(date +%F)}"
OUT_FILE="${SNAPSHOT_DIR}/${SNAPSHOT_DATE}.tsv"
TMP_FILE="$(mktemp)"

ensure_dir "$SNAPSHOT_DIR"
ensure_parent_dir "$LOCK_FILE"
trap 'rm -f "$TMP_FILE"' EXIT

exec 9>"$LOCK_FILE"
flock -n 9 || exit 0

mysql_exec "
SELECT id,
       COALESCE(username,''),
       COALESCE(status,0),
       COALESCE(role,0),
       COALESCE(\`group\`,''),
       COALESCE(quota,0),
       COALESCE(used_quota,0),
       COALESCE(request_count,0)
FROM users
WHERE deleted_at IS NULL
ORDER BY id;
" >"$TMP_FILE"

install -m 600 "$TMP_FILE" "$OUT_FILE"
ln -sfn "$OUT_FILE" "${SNAPSHOT_DIR}/latest.tsv"
log_with_ts "$NEWAPI_BUSINESS_REPORT_LOG" "captured user snapshot: ${OUT_FILE}"
