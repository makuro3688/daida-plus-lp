#!/usr/bin/env bash
# 共通処理。値を表示せず、設定不足は副作用の前に停止する。
set -Eeuo pipefail

backup_die() {
  echo "backup error: $1" >&2
  exit "${2:-64}"
}

require_env() {
  local name="$1"
  [[ -n "${!name:-}" ]] || backup_die "required setting is missing: ${name}"
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || backup_die "required command is unavailable: $1"
}

validate_age_public_key() {
  # age の完全な妥当性確認は age 自身に任せ、誤設定を早期に弾く。
  [[ "${AGE_PUBLIC_KEY:-}" =~ ^age1[ac-hj-np-z02-9]{20,}$ ]] || backup_die 'AGE_PUBLIC_KEY must be an age public key.'
}

validate_backup_path_component() {
  local value="$1" label="$2"
  [[ "$value" =~ ^[A-Za-z0-9][A-Za-z0-9._/-]*$ ]] || backup_die "${label} contains unsupported characters."
  [[ "$value" != *'..'* && "$value" != /* && "$value" != */ ]] || backup_die "${label} is unsafe."
}

validate_storage_path() {
  local path="$1"
  [[ -n "$path" && "$path" != /* && "$path" != *$'\n'* && "$path" != *$'\r'* && "$path" != *$'\t'* ]] || return 1
  local piece
  IFS='/' read -r -a pieces <<< "$path"
  for piece in "${pieces[@]}"; do
    [[ -n "$piece" && "$piece" != '.' && "$piece" != '..' ]] || return 1
  done
}

validate_safe_logical_path() {
  local path="$1" part
  [[ "$path" =~ ^[A-Za-z0-9][A-Za-z0-9._/-]*$ && "$path" != *'..'* && "$path" != */ && "$path" != /* ]] || return 1
  IFS='/' read -r -a pieces <<< "$path"
  for part in "${pieces[@]}"; do
    [[ "$part" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ && "$part" != *[.\ ] ]] || return 1
    case "${part^^}" in CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9]) return 1;; esac
  done
}

assert_descendant() {
  local base="$1" candidate="$2" canonical_base canonical_candidate
  canonical_base="$(cd "$base" && pwd -P)"
  canonical_candidate="$(cd "$(dirname "$candidate")" && pwd -P)/$(basename "$candidate")"
  [[ "$canonical_candidate" == "$canonical_base/"* ]] || backup_die 'refusing a path outside the requested output directory.'
}

sha256_of() {
  sha256sum "$1" | awk '{print $1}'
}

bytes_of() {
  wc -c < "$1" | tr -d '[:space:]'
}

record_artifact() {
  # 平文を暗号化してから消し、平文・暗号文双方の検証値を暗号化マニフェストへ残す。
  local logical_path="$1" plain_file="$2"
  [[ -f "$plain_file" && -s "$plain_file" ]] || backup_die "empty or missing artifact: ${logical_path}"
  validate_safe_logical_path "$logical_path" || backup_die "unsafe artifact path: ${logical_path}"
  local encrypted_file="${BACKUP_SNAPSHOT_DIR}/${logical_path}.age"
  mkdir -p "$(dirname "$encrypted_file")"
  local plain_bytes plain_hash encrypted_bytes encrypted_hash
  plain_bytes="$(bytes_of "$plain_file")"
  plain_hash="$(sha256_of "$plain_file")"
  age -r "$AGE_PUBLIC_KEY" -o "$encrypted_file" "$plain_file"
  [[ -s "$encrypted_file" ]] || backup_die "age produced an empty artifact: ${logical_path}"
  encrypted_bytes="$(bytes_of "$encrypted_file")"
  encrypted_hash="$(sha256_of "$encrypted_file")"
  printf '%s\t%s\t%s\t%s\t%s\n' "$logical_path" "$plain_bytes" "$plain_hash" "$encrypted_bytes" "$encrypted_hash" >> "$BACKUP_MANIFEST_TSV"
  rm -f -- "$plain_file"
}

gdrive_remote_size() {
  local remote_path="$1" remote_json remote_size
  remote_json="$(rclone size "gdrive:${remote_path}" --json)"
  remote_size="$(sed -n 's/.*"bytes"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p' <<< "$remote_json")"
  [[ "$remote_size" =~ ^[0-9]+$ ]] || backup_die 'Google Drive returned an invalid remote size.'
  printf '%s\n' "$remote_size"
}

upload_snapshot_to_prefix() {
  local class="$1" relative remote_path remote_size
  while IFS= read -r -d '' encrypted_file; do
    relative="${encrypted_file#"${BACKUP_SNAPSHOT_DIR}/"}"
    remote_path="${GDRIVE_ROOT}/snapshots/${class}/${BACKUP_SNAPSHOT_NAME}/${relative}"
    rclone copyto "$encrypted_file" "gdrive:${remote_path}" --no-traverse --check-first
    remote_size="$(gdrive_remote_size "$remote_path")"
    [[ "$remote_size" == "$(bytes_of "$encrypted_file")" ]] || backup_die "Google Drive size verification failed: ${relative}"
  done < <(find "$BACKUP_SNAPSHOT_DIR" -type f -print0 | sort -z)
}

trash_expired_snapshots() {
  local class="$1" retention_days="$2"
  [[ "$retention_days" =~ ^[1-9][0-9]{0,3}$ ]] || backup_die "invalid ${class} retention days."
  # 初回はmonthly等の保存先がまだ存在しないため、空の保存先を先に確保する。
  rclone mkdir "gdrive:${GDRIVE_ROOT}/snapshots/${class}"
  rclone delete "gdrive:${GDRIVE_ROOT}/snapshots/${class}" \
    --min-age "${retention_days}d" \
    --drive-use-trash=true \
    --checkers 4
}
