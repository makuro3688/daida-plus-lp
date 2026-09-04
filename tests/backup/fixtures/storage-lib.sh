#!/usr/bin/env bash
# backup-storage.sh のページングを大量ファイル暗号化なしで試すためのテスト専用lib。
set -Eeuo pipefail

backup_die() { echo "backup error: $1" >&2; exit "${2:-64}"; }
require_env() { local name="$1"; [[ -n "${!name:-}" ]] || backup_die "required setting is missing: ${name}"; }
require_command() { command -v "$1" >/dev/null 2>&1 || backup_die "required command is unavailable: $1"; }
validate_storage_path() {
  local path="$1" piece
  [[ -n "$path" && "$path" != /* && "$path" != *$'\n'* && "$path" != *$'\r'* && "$path" != *$'\t'* ]] || return 1
  IFS='/' read -r -a pieces <<< "$path"
  for piece in "${pieces[@]}"; do [[ -n "$piece" && "$piece" != . && "$piece" != .. ]] || return 1; done
}
record_artifact() {
  local logical_path="$1" plain_file="$2"
  [[ -s "$plain_file" ]] || backup_die "empty or missing artifact: ${logical_path}"
  printf '%s\n' "$logical_path" >> "$BACKUP_MANIFEST_TSV"
  if [[ "$logical_path" == storage-inventory.tsv ]]; then
    while IFS= read -r line || [[ -n "$line" ]]; do printf '%s\n' "$line"; done < "$plain_file" > "$BACKUP_SNAPSHOT_DIR/storage-inventory.tsv.age"
  fi
}
