#!/usr/bin/env bash
# 復号済みの DB ダンプを、明示確認済みの隔離 Postgres へ一括復元する。
set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

usage() { echo 'Usage: RESTORE_CONFIRM=restore-isolated-db restore-db.sh <decrypted-snapshot-dir> (uses 0600 RESTORE_DB_SERVICE_FILE)' >&2; exit 64; }
[[ "$#" == 1 ]] || usage
[[ "${RESTORE_CONFIRM:-}" == 'restore-isolated-db' ]] || backup_die 'Set RESTORE_CONFIRM=restore-isolated-db after confirming the target is isolated.'
require_env RESTORE_DB_SERVICE_FILE
require_env RESTORE_TARGET_PROJECT_REF
require_env RESTORE_PRODUCTION_PROJECT_REF
require_env RESTORE_DB_MARKER_VALUE
[[ "$RESTORE_TARGET_PROJECT_REF" =~ ^[a-z0-9]{20}$ && "$RESTORE_PRODUCTION_PROJECT_REF" =~ ^[a-z0-9]{20}$ && "$RESTORE_TARGET_PROJECT_REF" != "$RESTORE_PRODUCTION_PROJECT_REF" ]] || backup_die 'target and production project refs must be distinct 20-character refs.'
expected_host="db.${RESTORE_TARGET_PROJECT_REF}.supabase.co"
snapshot_dir="$1"
for file in roles.sql schema.sql data.sql; do [[ -s "$snapshot_dir/db/$file" ]] || backup_die "required DB dump is missing: $file"; done
require_command psql
if [[ "${OS:-}" == Windows_NT || "$(uname -s)" == MINGW* ]]; then
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$SCRIPT_DIR/verify-windows-acl.ps1" -Path "$(cygpath -w "$RESTORE_DB_SERVICE_FILE")" || backup_die 'Windows ACL verification failed.'
else
  [[ "$(stat -c '%a' "$RESTORE_DB_SERVICE_FILE")" == 600 ]] || backup_die 'RESTORE_DB_SERVICE_FILE must be mode 0600.'
fi
# daida_restoreだけを解析し、重複/hostaddr/余計な接続先キーを拒否する。
mapfile -t service_lines < <(awk '/^\[daida_restore\]$/{f=1;next} /^\[/{f=0} f && NF && $1 !~ /^#/{print}' "$RESTORE_DB_SERVICE_FILE")
declare -A service=(); for line in "${service_lines[@]}"; do key="${line%%=*}"; value="${line#*=}"; [[ "$line" == *=* && -z "${service[$key]:-}" ]] || backup_die 'invalid or duplicate restore service key.'; service[$key]="$value"; done
[[ -z "${service[hostaddr]:-}" && "${service[host]:-}" == "$expected_host" && "${service[dbname]:-}" == postgres && "${service[user]:-}" == postgres && "${service[port]:-}" == 5432 && "${service[sslmode]:-}" == require ]] || backup_die 'restore service does not exactly match isolated Supabase target.'
identity="$(PGSERVICEFILE="$RESTORE_DB_SERVICE_FILE" psql --no-psqlrc --tuples-only --no-align --dbname 'service=daida_restore' --command "select current_database() || E'\\t' || current_user")"
[[ "$identity" == postgres$'\t'postgres ]] || backup_die 'restore target database/user is not allowlisted.'
marker="$(PGSERVICEFILE="$RESTORE_DB_SERVICE_FILE" psql --no-psqlrc --tuples-only --no-align --dbname 'service=daida_restore' --command "select value from recovery_marker limit 1")"
[[ "$marker" == "$RESTORE_DB_MARKER_VALUE" ]] || backup_die 'restore target marker verification failed.'
PGSERVICEFILE="$RESTORE_DB_SERVICE_FILE" psql --no-psqlrc --single-transaction --variable=ON_ERROR_STOP=1 \
  --file "$snapshot_dir/db/roles.sql" \
  --file "$snapshot_dir/db/schema.sql" \
  --command 'SET session_replication_role = replica' \
  --file "$snapshot_dir/db/data.sql" \
  --dbname 'service=daida_restore'
echo 'database restore completed.'
