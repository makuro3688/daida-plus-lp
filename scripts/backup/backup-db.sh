#!/usr/bin/env bash
# Supabase 公式 CLI の論理バックアップ形式（roles/schema/data）を作成する。
set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

require_env SUPABASE_DB_URL_FILE
require_env BACKUP_PLAINTEXT_DIR
require_command supabase
[[ -f "$SUPABASE_DB_URL_FILE" ]] || backup_die 'SUPABASE_DB_URL_FILE is missing.'
if [[ "${OS:-}" == Windows_NT || "$(uname -s)" == MINGW* ]]; then
  require_command powershell.exe
  require_command cygpath
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$SCRIPT_DIR/verify-windows-acl.ps1" \
    -Path "$(cygpath -w "$SUPABASE_DB_URL_FILE")" || backup_die 'Windows ACL verification failed for SUPABASE_DB_URL_FILE.'
else
  [[ "$(stat -c '%a' "$SUPABASE_DB_URL_FILE")" == 600 ]] || backup_die 'SUPABASE_DB_URL_FILE must be mode 0600.'
fi

dump_file() {
  local output="$1"
  shift
  local db_url
  IFS= read -r db_url < "$SUPABASE_DB_URL_FILE"
  [[ "$db_url" == postgresql://* || "$db_url" == postgres://* ]] || backup_die 'SUPABASE_DB_URL_FILE does not contain a Postgres URL.'
  # Supabase CLI requires the URL as a command argument. The credential is restricted
  # to a read-only, non-admin backup role and the CLI binary is checksum-pinned.
  env -u AWS_ACCESS_KEY_ID -u AWS_SECRET_ACCESS_KEY -u GITHUB_TOKEN -u SUPABASE_STORAGE_SERVICE_ROLE_KEY -u BACKUP_HEARTBEAT_URL \
    supabase db dump --db-url "$db_url" -f "$output" "$@"
  db_url=''
  [[ -s "$output" ]] || backup_die "Supabase CLI produced an empty dump: $(basename "$output")"
}

mkdir -p "$BACKUP_PLAINTEXT_DIR/db"
dump_file "$BACKUP_PLAINTEXT_DIR/db/roles.sql" --role-only
record_artifact 'db/roles.sql' "$BACKUP_PLAINTEXT_DIR/db/roles.sql"
dump_file "$BACKUP_PLAINTEXT_DIR/db/schema.sql"
record_artifact 'db/schema.sql' "$BACKUP_PLAINTEXT_DIR/db/schema.sql"
dump_file "$BACKUP_PLAINTEXT_DIR/db/data.sql" --use-copy --data-only -x storage.buckets_vectors -x storage.vector_indexes
record_artifact 'db/data.sql' "$BACKUP_PLAINTEXT_DIR/db/data.sql"
