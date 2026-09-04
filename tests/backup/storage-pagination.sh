#!/usr/bin/env bash
# Storage API の 0/1/1000/1001 件境界を、動的 curl mock で高速に実行する。
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
temporary="$(mktemp -d)"
real_awk="$(command -v awk)"
trap 'unset -f awk base64 curl jq sed sha256sum 2>/dev/null || true; command rm -rf -- "$temporary"' EXIT

harness="$temporary/harness"
fast_harness="$temporary/fast-harness"
command mkdir -p "$harness"
command cp "$ROOT/scripts/backup/backup-storage.sh" "$harness/backup-storage.sh"
command cp "$ROOT/tests/backup/fixtures/storage-lib.sh" "$harness/lib.sh"
command chmod +x "$harness/backup-storage.sh"
command cp -R "$harness" "$fast_harness"
(cd "$fast_harness" && patch --quiet -p0 -i "$ROOT/tests/backup/fixtures/storage-fast-harness.patch")

# 1001オブジェクトでも外部プロセスをオブジェクトごとに起動しない軽量mock。
sha256sum() {
  local input='' digits value
  if [[ "$#" == 0 ]]; then
    IFS= read -r input || true
    digits="${input##*_}"
    [[ "$digits" =~ ^[0-9]+$ ]] || digits=0
    value=$((10#$digits + 1))
    printf '%064d  -\n' "$value"
  else
    printf '%064d  %s\n' 0 "$1"
  fi
}
sed() { command cat; }
base64() { command cat; }
awk() {
  if [[ "${1:-}" == '{print $1}' ]]; then
    local first rest
    IFS=' ' read -r first rest || true
    printf '%s\n' "$first"
  else
    "$real_awk" "$@"
  fi
}
jq() {
  local expression="${2:-}" file="${3:-}" offset count i
  if [[ "${1:-}" == '-cn' ]]; then
    while [[ "$#" -gt 0 ]]; do
      case "$1" in --argjson) [[ "$2" == offset ]] && offset="$3"; shift 3 ;; *) shift ;; esac
    done
    printf '{"offset":%s}\n' "${offset:-0}"
  elif [[ "${1:-}" == '-e' && "$expression" == type* ]]; then
    grep -Eq '^offset=[0-9]+ count=[0-9]+$' "$file"
  elif [[ "${1:-}" == '-e' && "$expression" == length ]]; then
    read -r offset count < "$file"
    printf '%s\n' "${count#count=}"
  elif [[ "${1:-}" == '-r' ]]; then
    read -r offset count < "$file"
    offset="${offset#offset=}"; count="${count#count=}"
    for ((i=0; i<count; i++)); do
      printf 'file\tobj_%06d\n' "$((offset + i))"
    done
  elif [[ "${1:-}" == '-sRr' ]]; then
    command cat
  else
    echo "unexpected jq invocation: $*" >&2
    return 2
  fi
}
curl() {
  local output='' payload='' url='' arg offset total remaining page_count
  while [[ "$#" -gt 0 ]]; do
    arg="$1"
    case "$arg" in
      -o) output="$2"; shift 2 ;;
      --data) payload="$2"; shift 2 ;;
      http*) url="$arg"; shift ;;
      *) shift ;;
    esac
  done
  if [[ "$url" == */object/list/* ]]; then
    offset="${payload##*:}"; offset="${offset%\}}"
    printf 'list\t%s\n' "$offset" >> "$MOCK_STORAGE_LOG"
    [[ "${MOCK_STORAGE_FAIL_OFFSET:-}" != "$offset" ]] || return 22
    total="$MOCK_STORAGE_COUNT"; remaining=$((total - offset))
    (( remaining < 0 )) && remaining=0
    (( remaining > 1000 )) && page_count=1000 || page_count="$remaining"
    printf 'offset=%s count=%s\n' "$offset" "$page_count" > "$output"
  else
    printf 'download\t%s\n' "$url" >> "$MOCK_STORAGE_LOG"
    printf 'x' > "$output"
  fi
}
export -f awk base64 curl jq sed sha256sum
export real_awk

run_case() {
  local count="$1" expected_pages="$2" case_dir tested_script
  case_dir="$temporary/count-${count}"
  if (( count <= 1 )) || [[ "${STORAGE_EXACT_COUNT:-}" == "$count" ]]; then
    tested_script="$harness/backup-storage.sh"
  else
    tested_script="$fast_harness/backup-storage.sh"
  fi
  command mkdir -p "$case_dir/plain/storage/testbucket/objects" "$case_dir/snapshot/storage/testbucket/objects"
  : > "$case_dir/manifest.tsv"
  : > "$case_dir/curl.log"
  export MOCK_STORAGE_COUNT="$count"
  export MOCK_STORAGE_LOG="$case_dir/curl.log"
  export BACKUP_STORAGE_ENABLED=true
  export SUPABASE_PROJECT_REF='abcdefghijklmnopqrst'
  export SUPABASE_STORAGE_CURL_CONFIG="$case_dir/curl.conf"
  export SUPABASE_STORAGE_BUCKETS='testbucket'
  export BACKUP_PLAINTEXT_DIR="$case_dir/plain"
  export BACKUP_SNAPSHOT_DIR="$case_dir/snapshot"
  export BACKUP_MANIFEST_TSV="$case_dir/manifest.tsv"
  export AGE_PUBLIC_KEY='age1mock'
  unset MOCK_STORAGE_FAIL_OFFSET
  : > "$SUPABASE_STORAGE_CURL_CONFIG"

  timeout "${STORAGE_CASE_TIMEOUT:-20}" "$tested_script"
  [[ "$(grep -c '^download' "$MOCK_STORAGE_LOG" || true)" == "$count" ]]
  [[ "$(grep -c '^list' "$MOCK_STORAGE_LOG" || true)" == "$expected_pages" ]]
  [[ "$("$real_awk" 'END {print NR}' "$case_dir/snapshot/storage-inventory.tsv.age")" == "$((count + 1))" ]]
  [[ "$(grep -c '^storage/testbucket/objects/.*\.bin$' "$BACKUP_MANIFEST_TSV" || true)" == "$count" ]]
  [[ "$(grep -c '^storage-inventory.tsv$' "$BACKUP_MANIFEST_TSV" || true)" == 1 ]]
  ! find "$case_dir/plain" -maxdepth 1 -type f -name 'list-*' -print -quit | grep -q .
  echo "PASS: Storage count=${count}, downloads=${count}, pages=${expected_pages}, inventory=$((count + 1)) lines"
}

run_case 0 1
run_case 1 1
run_case 1000 2
run_case 1001 2

failure_dir="$temporary/http-failure"
command mkdir -p "$failure_dir/plain/storage/testbucket/objects" "$failure_dir/snapshot/storage/testbucket/objects"
: > "$failure_dir/manifest.tsv"
: > "$failure_dir/curl.log"
export MOCK_STORAGE_COUNT=1001 MOCK_STORAGE_FAIL_OFFSET=1000 MOCK_STORAGE_LOG="$failure_dir/curl.log"
export BACKUP_PLAINTEXT_DIR="$failure_dir/plain" BACKUP_SNAPSHOT_DIR="$failure_dir/snapshot" BACKUP_MANIFEST_TSV="$failure_dir/manifest.tsv"
export SUPABASE_STORAGE_CURL_CONFIG="$failure_dir/curl.conf"
: > "$SUPABASE_STORAGE_CURL_CONFIG"
if timeout 20 "$fast_harness/backup-storage.sh" > "$failure_dir/output.log" 2>&1; then
  echo 'Storage HTTP failure case unexpectedly succeeded.' >&2
  exit 1
fi
[[ "$(grep -c '^list' "$MOCK_STORAGE_LOG")" == 2 ]]
[[ "$(grep -c '^download' "$MOCK_STORAGE_LOG")" == 1000 ]]
[[ ! -e "$failure_dir/snapshot/storage-inventory.tsv.age" ]]
echo 'PASS: Storage rejects an HTTP failure on the second page'
