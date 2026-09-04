#!/usr/bin/env bash
# 復号済みの Git ミラーを新しい作業ディレクトリへ復元する。
set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

usage() { echo 'Usage: restore-git.sh <decrypted-snapshot-dir> <new-working-copy-path>' >&2; exit 64; }
[[ "$#" == 2 ]] || usage
snapshot_dir="$1" destination="$2"
archive="$snapshot_dir/git/repository-mirror.tar.gz"
[[ -s "$archive" ]] || backup_die 'Git mirror archive is missing.'
[[ ! -e "$destination" ]] || backup_die 'destination must not already exist.'
require_command git
require_command tar
temporary="$(mktemp -d)"
trap 'rm -rf -- "$temporary"' EXIT
tar -xzf "$archive" -C "$temporary"
[[ -d "$temporary/repository.git" ]] || backup_die 'archive did not contain repository.git.'
git --git-dir="$temporary/repository.git" fsck --full --no-reflogs
git clone "$temporary/repository.git" "$destination"
echo "Git working copy restored: ${destination}"
