#!/usr/bin/env bash
# 本番と異なる接頭辞付きバケットへだけ、復号済み Storage オブジェクトを復元する。
set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

usage() { echo 'Usage: RESTORE_STORAGE_CONFIRM=restore-isolated-storage restore-storage.sh <decrypted-snapshot-dir>' >&2; exit 64; }
[[ "$#" == 1 ]] || usage
[[ "${RESTORE_STORAGE_CONFIRM:-}" == 'restore-isolated-storage' ]] || backup_die 'Set RESTORE_STORAGE_CONFIRM=restore-isolated-storage after creating isolated target buckets.'
require_env RESTORE_SUPABASE_PROJECT_REF
require_env RESTORE_STORAGE_CURL_CONFIG
require_env RESTORE_STORAGE_BUCKET_PREFIX
[[ "$RESTORE_STORAGE_BUCKET_PREFIX" =~ ^[a-z0-9][a-z0-9-]{0,30}-$ ]] || backup_die 'RESTORE_STORAGE_BUCKET_PREFIX must end in a hyphen.'
snapshot_dir="$1"
[[ -s "$snapshot_dir/storage-inventory.tsv" ]] || { echo 'No Storage artifacts to restore.'; exit 0; }
require_command curl
require_command jq
[[ "$RESTORE_SUPABASE_PROJECT_REF" =~ ^[a-z0-9]{20}$ ]] || backup_die 'RESTORE_SUPABASE_PROJECT_REF must be a 20-character project reference.'
api="https://${RESTORE_SUPABASE_PROJECT_REF}.supabase.co/storage/v1"
tail -n +2 "$snapshot_dir/storage-inventory.tsv" | while IFS=$'\t' read -r source_bucket object_b64; do
  [[ "$source_bucket" =~ ^[a-z0-9][a-z0-9-]{1,61}[a-z0-9]$ ]] || backup_die 'unsafe Storage bucket in inventory.'
  object="$(printf '%s' "$object_b64" | base64 --decode)"
  validate_storage_path "$object" || backup_die 'unsafe Storage object path.'
  object_id="$(printf '%s' "$object" | sha256sum | awk '{print $1}')"
  file="$snapshot_dir/storage/$source_bucket/objects/${object_id}.bin"
  [[ -s "$file" ]] || backup_die 'Storage inventory refers to a missing artifact.'
  target_bucket="${RESTORE_STORAGE_BUCKET_PREFIX}${source_bucket}"
  encoded="$(printf '%s' "${target_bucket}/${object}" | jq -sRr '@uri' | sed 's/%2F/\//g')"
  curl --config "$RESTORE_STORAGE_CURL_CONFIG" --fail --silent --show-error --max-time 300 --retry 2 \
    -X POST -H 'x-upsert: false' \
    --data-binary "@$file" "${api}/object/${encoded}"
done
echo 'Storage restore completed to isolated target buckets.'
