#!/usr/bin/env bash
# Storage は同期しない。全オブジェクトを日時別スナップショットへ個別に暗号化する。
set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

[[ "${BACKUP_STORAGE_ENABLED:-false}" == 'true' ]] || exit 0
require_env SUPABASE_PROJECT_REF
require_env SUPABASE_STORAGE_CURL_CONFIG
require_env SUPABASE_STORAGE_BUCKETS
require_env BACKUP_PLAINTEXT_DIR
require_command curl
require_command jq
require_command base64

[[ "$SUPABASE_PROJECT_REF" =~ ^[a-z0-9]{20}$ ]] || backup_die 'SUPABASE_PROJECT_REF must be the 20-character Supabase project reference.'
storage_api="https://${SUPABASE_PROJECT_REF}.supabase.co/storage/v1"
storage_counter=0
storage_inventory="$BACKUP_PLAINTEXT_DIR/storage-inventory.tsv"
printf 'bucket\tobject\n' > "$storage_inventory"
declare -A storage_seen=()

list_prefix() {
  local bucket="$1" prefix="$2" offset=0 response_file parsed_file count kind name object encoded temp_file object_id
  while :; do
    response_file="$BACKUP_PLAINTEXT_DIR/list-${storage_counter}.json"; storage_counter=$((storage_counter + 1))
    curl --config "$SUPABASE_STORAGE_CURL_CONFIG" --fail --silent --show-error --max-time 120 --retry 2 \
      -X POST "${storage_api}/object/list/${bucket}" \
      -H 'Content-Type: application/json' \
      --data "$(jq -cn --arg prefix "$prefix" --argjson offset "$offset" '{prefix:$prefix,limit:1000,offset:$offset,sortBy:{column:"name",order:"asc"}}')" -o "$response_file"
    jq -e 'type == "array" and all(.[]; type == "object" and (.name|type == "string") and ((.id == null) or (.id|type == "string")))' "$response_file" >/dev/null || backup_die "Storage API returned invalid JSON for bucket: ${bucket}"
    count="$(jq -e 'length' "$response_file")"
    parsed_file="$BACKUP_PLAINTEXT_DIR/list-${storage_counter}.tsv"; storage_counter=$((storage_counter + 1))
    jq -r '.[] | [if (.id == null) then "directory" else "file" end, (.name | @base64)] | @tsv' "$response_file" > "$parsed_file"
    while IFS=$'\t' read -r kind encoded_name; do
      name="$(printf '%s' "$encoded_name" | base64 --decode)"
      [[ -n "$name" ]] || continue
      object="${prefix}${name}"
      validate_storage_path "$object" || backup_die "Storage returned an unsafe object name."
      [[ -z "${storage_seen[${bucket}/$object]:-}" ]] || backup_die 'Storage returned a duplicate logical object.'
      storage_seen[${bucket}/$object]=1
      if [[ "$kind" == 'directory' ]]; then
        list_prefix "$bucket" "${object}/"
      else
        encoded="$(printf '%s' "${bucket}/${object}" | jq -sRr '@uri' | sed 's/%2F/\//g')"
        object_id="$(printf '%s' "$object" | sha256sum | awk '{print $1}')"
        temp_file="$BACKUP_PLAINTEXT_DIR/storage-${storage_counter}.bin"
        storage_counter=$((storage_counter + 1))
        curl --config "$SUPABASE_STORAGE_CURL_CONFIG" --fail --silent --show-error --max-time 300 --retry 2 -o "$temp_file" "${storage_api}/object/authenticated/${encoded}"
        record_artifact "storage/${bucket}/objects/${object_id}.bin" "$temp_file"
        printf '%s\t%s\n' "$bucket" "$(printf '%s' "$object" | base64 | tr -d '\n')" >> "$storage_inventory"
      fi
    done < "$parsed_file"
    rm -f -- "$response_file" "$parsed_file"
    (( count < 1000 )) && break
    offset=$((offset + count))
  done
}

IFS=',' read -r -a storage_buckets <<< "$SUPABASE_STORAGE_BUCKETS"
for bucket in "${storage_buckets[@]}"; do
  [[ "$bucket" =~ ^[a-z0-9][a-z0-9-]{1,61}[a-z0-9]$ ]] || backup_die 'SUPABASE_STORAGE_BUCKETS contains an invalid bucket name.'
  list_prefix "$bucket" ''
done
# 空のバケットも含め、復元時に対象範囲を確認できる暗号化インベントリを残す。
record_artifact 'storage-inventory.tsv' "$storage_inventory"
