#!/usr/bin/env bash
# 暗号化済みスナップショットを隔離ディレクトリに復号し、全ハッシュを検査する。
set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

usage() { echo 'Usage: inspect-backup.sh <downloaded-snapshot-dir> <age-secret-key-file-outside-repository> <trusted-signing-public-key-outside-repository> <empty-output-dir>' >&2; exit 64; }
[[ "$#" == 4 ]] || usage
snapshot_dir="$1" key_file="$2" verify_key="$3" output_dir="$4"
[[ -d "$snapshot_dir" && -f "$snapshot_dir/manifest.tsv.age" && -f "$snapshot_dir/root-manifest.tsv" && -f "$snapshot_dir/root-manifest.sig" && -f "$snapshot_dir/_SUCCESS" ]] || backup_die 'snapshot is missing a required manifest, signature, or _SUCCESS marker.'
[[ -f "$key_file" ]] || backup_die 'age secret key file is missing.'
[[ -f "$verify_key" ]] || backup_die 'trusted signing public key is missing.'
[[ ! -e "$output_dir" ]] || backup_die 'output directory must not already exist.'
require_command age
require_command sha256sum
require_command openssl
snapshot_id="$(basename "$snapshot_dir")"
[[ "$(<"$snapshot_dir/_SUCCESS")" == "$snapshot_id" ]] || backup_die '_SUCCESS marker does not match snapshot directory.'
grep -Fxq $'format\tbackup-root-v1' "$snapshot_dir/root-manifest.tsv" || backup_die 'root manifest format is invalid.'
grep -Fxq $'snapshot\t'"${snapshot_id}" "$snapshot_dir/root-manifest.tsv" || backup_die 'root manifest snapshot id is invalid.'
openssl pkeyutl -verify -pubin -inkey "$verify_key" -rawin -in "$snapshot_dir/root-manifest.tsv" -sigfile "$snapshot_dir/root-manifest.sig" >/dev/null || backup_die 'root manifest signature verification failed.'
root_count=0
declare -A root_seen=()
while IFS=$'\t' read -r root_path root_hash; do
  [[ -z "$root_path" || "$root_path" == format || "$root_path" == snapshot ]] && continue
  validate_safe_logical_path "$root_path" || backup_die 'unsafe root manifest path.'
  [[ "$root_path" == *.age && "$root_hash" =~ ^[a-f0-9]{64}$ && -z "${root_seen[$root_path]:-}" ]] || backup_die 'invalid or duplicate root manifest entry.'
  root_seen[$root_path]=1; ((root_count+=1))
  [[ -s "$snapshot_dir/$root_path" && "$(sha256_of "$snapshot_dir/$root_path")" == "$root_hash" ]] || backup_die "root manifest checksum failed: $root_path"
done < "$snapshot_dir/root-manifest.tsv"
(( root_count >= 5 )) || backup_die 'root manifest has too few artifacts.'
while IFS= read -r -d '' encrypted; do
  relative="${encrypted#"$snapshot_dir/"}"
  [[ -n "${root_seen[$relative]:-}" ]] || backup_die "unexpected encrypted artifact: $relative"
done < <(find "$snapshot_dir" -type f -name '*.age' -print0)
mkdir -p "$output_dir"
age -d -i "$key_file" -o "$output_dir/manifest.tsv" "$snapshot_dir/manifest.tsv.age"
[[ -s "$output_dir/manifest.tsv" ]] || backup_die 'decrypted manifest is empty.'

mapfile -t manifest_header < <(head -n 6 "$output_dir/manifest.tsv")
[[ "${manifest_header[0]:-}" == $'format\tage-encrypted-snapshot-v1' && "${manifest_header[2]:-}" == $'snapshot\t'"${snapshot_id}" && ( "${manifest_header[3]:-}" == $'storage_enabled\ttrue' || "${manifest_header[3]:-}" == $'storage_enabled\tfalse' ) && "${manifest_header[5]:-}" == $'logical_path\tplain_bytes\tplain_sha256\tencrypted_bytes\tencrypted_sha256' ]] || backup_die 'manifest header is invalid.'
declare -A logical_seen=(); required='db/roles.sql db/schema.sql db/data.sql git/repository-mirror.tar.gz'; artifact_count=0
while IFS=$'\t' read -r logical plain_bytes plain_hash encrypted_bytes encrypted_hash; do
  [[ -n "$logical" ]] || continue
  validate_safe_logical_path "$logical" || backup_die 'manifest contains an unsafe path.'
  [[ -z "${logical_seen[$logical]:-}" && "$plain_bytes" =~ ^[1-9][0-9]*$ && "$encrypted_bytes" =~ ^[1-9][0-9]*$ && "$plain_hash" =~ ^[a-f0-9]{64}$ && "$encrypted_hash" =~ ^[a-f0-9]{64}$ ]] || backup_die 'manifest contains duplicate or malformed artifact metadata.'
  logical_seen[$logical]=1; ((artifact_count+=1))
  encrypted="$snapshot_dir/${logical}.age"
  decrypted="$output_dir/$logical"
  [[ -s "$encrypted" ]] || backup_die "encrypted artifact is missing: ${logical}"
  [[ "$(bytes_of "$encrypted")" == "$encrypted_bytes" && "$(sha256_of "$encrypted")" == "$encrypted_hash" ]] || backup_die "encrypted artifact checksum failed: ${logical}"
  mkdir -p "$(dirname "$decrypted")"; assert_descendant "$output_dir" "$decrypted"
  age -d -i "$key_file" -o "$decrypted" "$encrypted"
  [[ -s "$decrypted" ]] || backup_die "decrypted artifact is empty: ${logical}"
  [[ "$(bytes_of "$decrypted")" == "$plain_bytes" && "$(sha256_of "$decrypted")" == "$plain_hash" ]] || backup_die "plaintext artifact checksum failed: ${logical}"
done < <(tail -n +7 "$output_dir/manifest.tsv")
for item in $required; do [[ -n "${logical_seen[$item]:-}" ]] || backup_die "required artifact missing: $item"; done
if [[ "${manifest_header[3]}" == $'storage_enabled\ttrue' ]]; then [[ -n "${logical_seen[storage-inventory.tsv]:-}" && "${manifest_header[4]}" != $'storage_buckets\t' ]] || backup_die 'Storage manifest metadata is incomplete.'; fi
[[ "$root_count" == $((artifact_count + 1)) && -n "${root_seen[manifest.tsv.age]:-}" ]] || backup_die 'root manifest must include exactly one additional manifest.tsv.age entry.'
echo "inspection completed: ${output_dir}"
