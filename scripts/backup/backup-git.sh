#!/usr/bin/env bash
# GitHub 側からミラーを取り、ローカル作業ツリーではなく全参照を保存する。
set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

require_env BACKUP_PLAINTEXT_DIR
require_command base64
require_command git
require_command tar

if [[ -n "${GIT_BACKUP_SOURCE_URL:-}" ]]; then
  source_url="$GIT_BACKUP_SOURCE_URL"
else
  require_env GITHUB_REPOSITORY
  require_env GITHUB_SERVER_URL
  require_env GITHUB_TOKEN
  source_url="${GITHUB_SERVER_URL}/${GITHUB_REPOSITORY}.git"
fi

repo_dir="$BACKUP_PLAINTEXT_DIR/git/repository.git"
archive="$BACKUP_PLAINTEXT_DIR/git/repository-mirror.tar.gz"
mkdir -p "$BACKUP_PLAINTEXT_DIR/git"
if [[ -n "${GITHUB_TOKEN:-}" && -z "${GIT_BACKUP_SOURCE_URL:-}" ]]; then
  # トークンを URL や標準出力へ出さず、Git の一回限りの HTTP ヘッダーとして渡す。
  git_auth_header="AUTHORIZATION: basic $(printf 'x-access-token:%s' "$GITHUB_TOKEN" | base64 | tr -d '\r\n')"
  GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=http.extraheader \
    GIT_CONFIG_VALUE_0="$git_auth_header" \
    git clone --mirror "$source_url" "$repo_dir"
  git_auth_header=''
  unset git_auth_header
else
  git clone --mirror "$source_url" "$repo_dir"
fi
git --git-dir="$repo_dir" fsck --full --no-reflogs
tar -C "$BACKUP_PLAINTEXT_DIR/git" -czf "$archive" repository.git
[[ -s "$archive" ]] || backup_die 'Git mirror archive is empty.'
rm -rf -- "$repo_dir"
record_artifact 'git/repository-mirror.tar.gz' "$archive"
