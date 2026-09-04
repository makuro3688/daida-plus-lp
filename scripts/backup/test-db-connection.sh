#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 5 || ! -f "$1" ]]; then
  echo "Usage: $0 <password-file> <host> <port> <database> <user>" >&2
  exit 2
fi

secret_file=$1
host=$2
port=$3
database=$4
user=$5
password_file=$(mktemp)
dump_dir=$(mktemp -d)

cleanup() {
  rm -f -- "$password_file" "$secret_file"
  rm -rf -- "$dump_dir"
}
trap cleanup EXIT

chmod 600 "$password_file"
IFS= read -r db_pass < "$secret_file"
db_pass=${db_pass//\\/\\\\}
db_pass=${db_pass//:/\\:}
printf '%s:%s:%s:%s:%s\n' \
  "$host" "$port" "$database" "$user" "$db_pass" > "$password_file"
unset db_pass

PGPASSFILE="$password_file" PGSSLMODE=require \
  psql -h "$host" -p "$port" -d "$database" -U "$user" \
  -v ON_ERROR_STOP=1 -Atqc 'select 1' \
  | grep -qx '1'

privilege_summary=$(
  PGPASSFILE="$password_file" PGSSLMODE=require \
    psql -h "$host" -p "$port" -d "$database" -U "$user" \
    -v ON_ERROR_STOP=1 -Atqc "
      with writable_tables as (
        select 1
        from pg_class c
        join pg_namespace n on n.oid = c.relnamespace
        where c.relkind in ('r', 'p')
          and n.nspname not in ('pg_catalog', 'information_schema')
          and n.nspname not like 'pg_toast%'
          and has_table_privilege(
            current_user,
            c.oid,
            'INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER'
          )
      ), creatable_schemas as (
        select 1
        from pg_namespace n
        where n.nspname not like 'pg_%'
          and n.nspname <> 'information_schema'
          and has_schema_privilege(current_user, n.oid, 'CREATE')
      )
      select
        (select count(*) from writable_tables) || '|' ||
        (select count(*) from creatable_schemas) || '|' ||
        pg_has_role(current_user, 'pg_write_all_data', 'member') || '|' ||
        has_database_privilege(current_user, current_database(), 'CREATE');
    "
)

if [[ "$privilege_summary" != '0|0|false|false' ]]; then
  echo "BACKUP_ROLE_IS_NOT_READ_ONLY:$privilege_summary" >&2
  exit 1
fi

PGPASSFILE="$password_file" PGSSLMODE=require \
  pg_dump -h "$host" -p "$port" -d "$database" -U "$user" \
  --schema-only --no-owner --no-acl \
  -f "$dump_dir/schema.sql"

PGPASSFILE="$password_file" PGSSLMODE=require \
  pg_dump -h "$host" -p "$port" -d "$database" -U "$user" \
  --data-only --no-owner --no-acl \
  --exclude-table-data='storage.buckets_vectors' \
  --exclude-table-data='storage.vector_indexes' \
  -f "$dump_dir/data.sql"

[[ -s "$dump_dir/schema.sql" && -s "$dump_dir/data.sql" ]]

PGPASSFILE="$password_file" PGSSLMODE=require \
  pg_dumpall -h "$host" -p "$port" -U "$user" \
  --roles-only --no-role-passwords \
  -f "$dump_dir/roles.sql"

[[ -s "$dump_dir/roles.sql" ]]

echo 'DB_CONNECTION_READ_ONLY_AND_DUMP_OK'
