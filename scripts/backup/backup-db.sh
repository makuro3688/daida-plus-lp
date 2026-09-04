#!/usr/bin/env bash
# Supabase互換のroles/schema/data論理バックアップを、専用の読取りユーザーで作成する。
set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

require_env SUPABASE_DB_URL_FILE
require_env SUPABASE_POSTGRES_IMAGE
require_env BACKUP_PLAINTEXT_DIR
require_command docker
[[ -f "$SUPABASE_DB_URL_FILE" ]] || backup_die 'SUPABASE_DB_URL_FILE is missing.'
if [[ "${OS:-}" == Windows_NT || "$(uname -s)" == MINGW* ]]; then
  require_command powershell.exe
  require_command cygpath
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$SCRIPT_DIR/verify-windows-acl.ps1" \
    -Path "$(cygpath -w "$SUPABASE_DB_URL_FILE")" || backup_die 'Windows ACL verification failed for SUPABASE_DB_URL_FILE.'
else
  [[ "$(stat -c '%a' "$SUPABASE_DB_URL_FILE")" == 600 ]] || backup_die 'SUPABASE_DB_URL_FILE must be mode 0600.'
fi
[[ "$SUPABASE_POSTGRES_IMAGE" =~ ^public\.ecr\.aws/supabase/postgres:[A-Za-z0-9._-]+@sha256:[a-f0-9]{64}$ ]] \
  || backup_die 'SUPABASE_POSTGRES_IMAGE must be a digest-pinned Supabase image.'

mapfile -t db_url_lines < "$SUPABASE_DB_URL_FILE"
[[ "${#db_url_lines[@]}" == 1 ]] || backup_die 'SUPABASE_DB_URL_FILE must contain exactly one line.'
db_url="${db_url_lines[0]}"
[[ "$db_url" == postgresql://* || "$db_url" == postgres://* ]] || backup_die 'SUPABASE_DB_URL_FILE does not contain a Postgres URL.'

# Dockerの--env-file経由で渡し、接続URLをホスト側のプロセス引数へ出さない。
pg_env_file="$(mktemp)"
cleanup_db_env() { rm -f -- "$pg_env_file"; }
trap cleanup_db_env EXIT
chmod 600 "$pg_env_file"
printf 'PGDATABASE=%s\nPGSSLMODE=require\nPGOPTIONS=-c statement_timeout=0\n' "$db_url" > "$pg_env_file"
db_url=''
unset db_url db_url_lines

run_pg_client() {
  docker run --rm --network host --env-file "$pg_env_file" \
    "$SUPABASE_POSTGRES_IMAGE" "$@"
}

mkdir -p "$BACKUP_PLAINTEXT_DIR/db"

# Supabase CLI 2.67.1のフィルタを維持し、管理者切替(--role postgres)だけを除く。
# --no-role-passwordsにより、ログインロールのパスワードハッシュは保存しない。
reserved_roles='anon|authenticated|authenticator|dashboard_user|pgbouncer|postgres|service_role|supabase_admin|supabase_auth_admin|supabase_etl_admin|supabase_functions_admin|supabase_read_only_user|supabase_realtime_admin|supabase_replication_admin|supabase_storage_admin|pgsodium_keyholder|pgsodium_keyiduser|pgsodium_keymaker|pgtle_admin'
allowed_configs='pgaudit.*|pgrst.*|session_replication_role|statement_timeout|track_io_timing'
roles_output="$BACKUP_PLAINTEXT_DIR/db/roles.sql"
run_pg_client pg_dumpall \
  --roles-only \
  --quote-all-identifiers \
  --no-role-passwords \
  --no-comments \
  --no-password \
| sed -E 's/^\\(un)?restrict .*$/-- &/' \
| sed -E "s/^CREATE ROLE \"(${reserved_roles})\"/-- &/" \
| sed -E "s/^ALTER ROLE \"(${reserved_roles})\"/-- &/" \
| sed -E 's/ (NOSUPERUSER|NOREPLICATION)//g' \
| sed -E "s/^-- (.* SET \"(${allowed_configs})\" .*)/\1/" \
| sed -E "s/GRANT \".*\" TO \"(${reserved_roles})\"/-- &/" \
| sed -E '/^--/d' \
| uniq > "$roles_output"
printf 'RESET ALL;\n' >> "$roles_output"
[[ -s "$roles_output" ]] || backup_die 'PostgreSQL produced an empty roles dump.'
record_artifact 'db/roles.sql' "$roles_output"

internal_schemas='information_schema|pg_*|_analytics|_realtime|_supavisor|auth|extensions|pgbouncer|realtime|storage|supabase_functions|supabase_migrations|cron|dbdev|graphql|graphql_public|net|pgmq|pgsodium|pgsodium_masks|pgtle|repack|tiger|tiger_data|timescaledb_*|_timescaledb_*|topology|vault'
schema_output="$BACKUP_PLAINTEXT_DIR/db/schema.sql"
run_pg_client pg_dump \
  --schema-only \
  --quote-all-identifiers \
  --no-password \
  --exclude-schema "$internal_schemas" \
| sed -E 's/^\\(un)?restrict .*$/-- &/' \
| sed -E 's/^CREATE SCHEMA "/CREATE SCHEMA IF NOT EXISTS "/' \
| sed -E 's/^CREATE TABLE "/CREATE TABLE IF NOT EXISTS "/' \
| sed -E 's/^CREATE SEQUENCE "/CREATE SEQUENCE IF NOT EXISTS "/' \
| sed -E 's/^CREATE VIEW "/CREATE OR REPLACE VIEW "/' \
| sed -E 's/^CREATE FUNCTION "/CREATE OR REPLACE FUNCTION "/' \
| sed -E 's/^CREATE TRIGGER "/CREATE OR REPLACE TRIGGER "/' \
| sed -E 's/^CREATE PUBLICATION "supabase_realtime/-- &/' \
| sed -E 's/^CREATE EVENT TRIGGER /-- &/' \
| sed -E 's/^         WHEN TAG IN /-- &/' \
| sed -E 's/^   EXECUTE FUNCTION /-- &/' \
| sed -E 's/^ALTER EVENT TRIGGER /-- &/' \
| sed -E 's/^ALTER PUBLICATION "supabase_realtime_/-- &/' \
| sed -E 's/^ALTER FOREIGN DATA WRAPPER (.+) OWNER TO /-- &/' \
| sed -E 's/^ALTER DEFAULT PRIVILEGES FOR ROLE "supabase_admin"/-- &/' \
| sed -E "s/^GRANT (.+) ON (.+) \"(${internal_schemas})\"/-- &/" \
| sed -E "s/^REVOKE (.+) ON (.+) \"(${internal_schemas})\"/-- &/" \
| sed -E 's/^(CREATE EXTENSION IF NOT EXISTS "pg_tle").+/\1;/' \
| sed -E 's/^(CREATE EXTENSION IF NOT EXISTS "pgsodium").+/\1;/' \
| sed -E 's/^(CREATE EXTENSION IF NOT EXISTS "pgmq").+/\1;/' \
| sed -E 's/^COMMENT ON EXTENSION (.+)/-- &/' \
| sed -E 's/^CREATE POLICY "cron_job_/-- &/' \
| sed -E 's/^ALTER TABLE "cron"/-- &/' \
| sed -E 's/^SET transaction_timeout = 0;/-- &/' \
| sed -E '/^--/d' > "$schema_output"
[[ -s "$schema_output" ]] || backup_die 'PostgreSQL produced an empty schema dump.'
record_artifact 'db/schema.sql' "$schema_output"

data_excluded_schemas='information_schema|pg_*|graphql|graphql_public|pgsodium|pgsodium_masks|pgtle|repack|tiger|tiger_data|timescaledb_*|_timescaledb_*|topology|vault|extensions|pgbouncer|realtime|supabase_migrations|_analytics|_realtime|_supavisor'
data_output="$BACKUP_PLAINTEXT_DIR/db/data.sql"
{
  printf 'SET session_replication_role = replica;\n\n'
  run_pg_client pg_dump \
    --data-only \
    --quote-all-identifiers \
    --no-password \
    --exclude-schema "$data_excluded_schemas" \
    --exclude-table 'auth.schema_migrations' \
    --exclude-table 'storage.migrations' \
    --exclude-table 'supabase_functions.migrations' \
    --exclude-table 'storage.buckets_vectors' \
    --exclude-table 'storage.vector_indexes' \
    --schema '*' \
  | sed -E 's/^\\(un)?restrict .*$/-- &/'
  printf 'RESET ALL;\n'
} > "$data_output"
[[ -s "$data_output" ]] || backup_die 'PostgreSQL produced an empty data dump.'
record_artifact 'db/data.sql' "$data_output"
