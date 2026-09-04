#!/usr/bin/env bash
# すべての平文は一時ディレクトリでのみ扱い、終了時に削除する。
set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

require_env AGE_PUBLIC_KEY
require_env GDRIVE_ROOT
require_env RCLONE_CONFIG_GDRIVE_CLIENT_ID
require_env RCLONE_CONFIG_GDRIVE_CLIENT_SECRET
require_env RCLONE_CONFIG_GDRIVE_TOKEN
require_env SUPABASE_DB_URL_FILE
require_env BACKUP_SIGNING_KEY_FILE
require_env GDRIVE_RESIDUAL_RISK_ACCEPTED
[[ "$GDRIVE_RESIDUAL_RISK_ACCEPTED" == 'true' ]] || backup_die 'GDRIVE_RESIDUAL_RISK_ACCEPTED=true is required before uploading.'
validate_age_public_key
validate_backup_path_component "$GDRIVE_ROOT" GDRIVE_ROOT
require_command age
require_command rclone
require_command sha256sum
require_command find
require_command openssl
require_command git
require_command tar

# 全設定を外部取得より前に確認する。Storageは有効化を明示した場合だけ資格情報を要求する。
case "${BACKUP_STORAGE_ENABLED:-false}" in
  false) ;;
  true)
    require_env SUPABASE_PROJECT_REF
    require_env SUPABASE_STORAGE_CURL_CONFIG
    require_env SUPABASE_STORAGE_BUCKETS
    require_command curl
    require_command jq
    require_command base64
    ;;
  *) backup_die 'BACKUP_STORAGE_ENABLED must be true or false.' ;;
esac
if [[ -z "${GIT_BACKUP_SOURCE_URL:-}" ]]; then
  require_env GITHUB_REPOSITORY
  require_env GITHUB_SERVER_URL
  require_env GITHUB_TOKEN
fi

snapshot_time="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
snapshot_stamp="$(date -u '+%Y%m%dT%H%M%SZ')"
snapshot_id="${BACKUP_SNAPSHOT_ID:-$(date -u '+%s')-${RANDOM}}"
[[ "$snapshot_id" =~ ^[A-Za-z0-9._-]+$ ]] || backup_die 'BACKUP_SNAPSHOT_ID contains unsupported characters.'
export BACKUP_SNAPSHOT_NAME="${snapshot_stamp}-${snapshot_id}"
export BACKUP_STAGE_DIR="$(mktemp -d)"
export BACKUP_SNAPSHOT_DIR="$BACKUP_STAGE_DIR/snapshot"
export BACKUP_PLAINTEXT_DIR="$BACKUP_STAGE_DIR/plaintext"
export BACKUP_MANIFEST_TSV="$BACKUP_STAGE_DIR/manifest.tsv"
cleanup() { rm -rf -- "$BACKUP_STAGE_DIR"; }
trap cleanup EXIT
mkdir -p "$BACKUP_SNAPSHOT_DIR" "$BACKUP_PLAINTEXT_DIR"
printf 'format\tage-encrypted-snapshot-v1\ncreated_at\t%s\nsnapshot\t%s\nstorage_enabled\t%s\nstorage_buckets\t%s\nlogical_path\tplain_bytes\tplain_sha256\tencrypted_bytes\tencrypted_sha256\n' \
  "$snapshot_time" "$BACKUP_SNAPSHOT_NAME" "${BACKUP_STORAGE_ENABLED:-false}" "${SUPABASE_STORAGE_BUCKETS:-}" > "$BACKUP_MANIFEST_TSV"

"$SCRIPT_DIR/backup-db.sh"
"$SCRIPT_DIR/backup-storage.sh"
"$SCRIPT_DIR/backup-git.sh"

# マニフェストも暗号化するため、Google Drive上に平文のファイル名・ハッシュを残さない。
record_artifact 'manifest.tsv' "$BACKUP_MANIFEST_TSV"
find "$BACKUP_PLAINTEXT_DIR" -type f -print -quit | grep -q . && backup_die 'plaintext artifact remained after encryption.'

# 暗号化とは独立した署名で、Google Drive書込み資格情報だけによる偽造を検出する。
root="$BACKUP_SNAPSHOT_DIR/root-manifest.tsv"
{ printf 'format\tbackup-root-v1\nsnapshot\t%s\n' "$BACKUP_SNAPSHOT_NAME"; find "$BACKUP_SNAPSHOT_DIR" -type f -name '*.age' -print0 | sort -z | while IFS= read -r -d '' f; do printf '%s\t%s\n' "${f#"$BACKUP_SNAPSHOT_DIR/"}" "$(sha256_of "$f")"; done; } > "$root"
openssl pkeyutl -sign -rawin -inkey "$BACKUP_SIGNING_KEY_FILE" -in "$root" -out "$BACKUP_SNAPSHOT_DIR/root-manifest.sig"
[[ -s "$BACKUP_SNAPSHOT_DIR/root-manifest.sig" ]] || backup_die 'root manifest signature is empty.'

upload_snapshot_to_prefix daily
classes=(daily)
if [[ "$(TZ=Asia/Tokyo date '+%d')" == '01' ]]; then
  upload_snapshot_to_prefix monthly
  classes+=(monthly)
fi

# 全アップロードの後だけ完了markerを置く。復元候補はこのmarkerを必須とする。
printf '%s\n' "$BACKUP_SNAPSHOT_NAME" > "$BACKUP_STAGE_DIR/_SUCCESS"
for class in "${classes[@]}"; do
  marker_path="${GDRIVE_ROOT}/snapshots/${class}/${BACKUP_SNAPSHOT_NAME}/_SUCCESS"
  rclone copyto "$BACKUP_STAGE_DIR/_SUCCESS" "gdrive:${marker_path}" --no-traverse --check-first
  marker_size="$(gdrive_remote_size "$marker_path")"
  [[ "$marker_size" == "$(bytes_of "$BACKUP_STAGE_DIR/_SUCCESS")" ]] || backup_die 'Google Drive _SUCCESS size verification failed.'
done

# 削除はGoogle Driveのゴミ箱へ移す。ゴミ箱を自動的に空にしない。
trash_expired_snapshots daily "${GDRIVE_DAILY_RETENTION_DAYS:-35}"
trash_expired_snapshots monthly "${GDRIVE_MONTHLY_RETENTION_DAYS:-400}"

if [[ -n "${BACKUP_HEARTBEAT_URL:-}" ]]; then
  # すべてのGoogle Driveアップロードと世代整理の成功後だけ、外部監視に成功を通知する。
  curl --fail --silent --show-error --max-time 20 --retry 2 -X POST "$BACKUP_HEARTBEAT_URL" >/dev/null
fi
echo "backup completed: ${BACKUP_SNAPSHOT_NAME}"
