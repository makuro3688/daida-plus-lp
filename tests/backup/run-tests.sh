#!/usr/bin/env bash
# 本番へ接続しない。外部コマンドをモックして失敗時に停止することを検証する。
set -Eeuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); echo "PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL: $1" >&2; }
expect_failure() {
  local name="$1"; shift
  if timeout 10 "$@" >/dev/null 2>&1; then
    fail "$name (unexpected success)"
  else
    rc=$?
    if [[ "$rc" == 124 ]]; then fail "$name (timed out)"; else pass "$name"; fi
  fi
}

temporary="$(mktemp -d)"
trap 'rm -rf -- "$temporary"' EXIT
mockbin="$temporary/bin"
mkdir -p "$mockbin"

cat > "$mockbin/age" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
[[ "${MOCK_AGE_FAIL:-}" != 1 ]] || exit 91
while [[ "$#" -gt 0 ]]; do
  case "$1" in -o) output="$2"; shift 2;; -r|-i) shift 2;; -d) shift;; *) input="$1"; shift;; esac
done
cp "$input" "$output"
EOF
cat > "$mockbin/rclone" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
[[ "${MOCK_RCLONE_FAIL:-}" != 1 ]] || exit 92
printf '%s\n' "$*" >> "${MOCK_RCLONE_LOG}"
if [[ "$1" == 'copyto' ]]; then
  source_file="$2"; destination="$3"; target="${MOCK_GDRIVE_ROOT}/${destination#gdrive:}"
  mkdir -p "$(dirname "$target")"; cp "$source_file" "$target"
elif [[ "$1" == 'size' ]]; then
  target="${MOCK_GDRIVE_ROOT}/${2#gdrive:}"
  size="$(wc -c < "$target" | tr -d '[:space:]')"
  printf '{"count":1,"bytes":%s,"sizeless":0}\n' "$size"
elif [[ "$1" == 'delete' ]]; then
  exit 0
else
  echo "unexpected rclone invocation: $*" >&2
  exit 2
fi
EOF
cat > "$mockbin/supabase" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
[[ "${MOCK_NPX_FAIL:-}" != 1 ]] || exit 93
while [[ "$#" -gt 0 ]]; do
  if [[ "$1" == '-f' ]]; then output="$2"; break; fi
  shift
done
[[ "${MOCK_NPX_EMPTY:-}" != 1 ]] && printf '%s\n' '-- mock SQL dump' > "$output"
EOF
cat > "$mockbin/openssl" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
[[ " $* " == *' -verify '* ]] && exit 0
while [[ "$#" -gt 0 ]]; do case "$1" in -in) input="$2"; shift 2;; -out) output="$2"; shift 2;; *) shift;; esac; done
cp "$input" "$output"
EOF
chmod +x "$mockbin/age" "$mockbin/rclone" "$mockbin/supabase" "$mockbin/openssl"

export PATH="$mockbin:$PATH"
export AGE_PUBLIC_KEY='age1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq'
export GDRIVE_ROOT='DAIDA-BACKUPS'
export RCLONE_CONFIG_GDRIVE_CLIENT_ID='test-client-id.apps.googleusercontent.com'
export RCLONE_CONFIG_GDRIVE_CLIENT_SECRET='test-client-secret'
export RCLONE_CONFIG_GDRIVE_TOKEN='{"access_token":"test-only"}'
printf '%s\n' 'postgresql://backup-reader:test-only@test.invalid:5432/postgres' > "$temporary/supabase-db-url"
printf '%s\n' 'mock signing key' > "$temporary/signing.pem"
chmod 600 "$temporary/supabase-db-url" "$temporary/signing.pem"
export SUPABASE_DB_URL_FILE="$temporary/supabase-db-url"
export BACKUP_SIGNING_KEY_FILE="$temporary/signing.pem"
export GDRIVE_RESIDUAL_RISK_ACCEPTED=true
export BACKUP_STORAGE_ENABLED='false'
test_repo="$temporary/minimal-repo"
git init -q "$test_repo"
git -C "$test_repo" config user.email backup-test@example.invalid
git -C "$test_repo" config user.name backup-test
printf '%s\n' test > "$test_repo/README"
git -C "$test_repo" add README && git -C "$test_repo" commit -qm test
export GIT_BACKUP_SOURCE_URL="$test_repo"
export MOCK_RCLONE_LOG="$temporary/rclone.log"
export MOCK_GDRIVE_ROOT="$temporary/google-drive"
chmod +x "$ROOT"/scripts/backup/*.sh

expect_failure 'AC-5 missing Google Drive setting fails before backup' env -u GDRIVE_ROOT "$ROOT/scripts/backup/run-backup.sh"
expect_failure 'AC-6 command failure fails closed' env MOCK_NPX_FAIL=1 "$ROOT/scripts/backup/run-backup.sh"
expect_failure 'AC-6 empty DB dump fails closed' env MOCK_NPX_EMPTY=1 "$ROOT/scripts/backup/run-backup.sh"
expect_failure 'AC-6 encryption failure fails closed' env MOCK_AGE_FAIL=1 "$ROOT/scripts/backup/run-backup.sh"
expect_failure 'AC-6 upload failure fails closed' env MOCK_RCLONE_FAIL=1 "$ROOT/scripts/backup/run-backup.sh"
expect_failure 'AC-3 enabled Storage without buckets fails closed' env BACKUP_STORAGE_ENABLED=true SUPABASE_STORAGE_BUCKETS='' "$ROOT/scripts/backup/run-backup.sh"
expect_failure 'AC-3 unknown Storage mode fails closed' env BACKUP_STORAGE_ENABLED=auto "$ROOT/scripts/backup/run-backup.sh"

if BACKUP_SNAPSHOT_ID='test-run' timeout 15 "$ROOT/scripts/backup/run-backup.sh" >/dev/null 2>&1 && [[ "$(wc -l < "$MOCK_RCLONE_LOG")" -ge 10 ]]; then
  pass 'AC-1/2/4/6 normal daily snapshot uploads encrypted artifacts and manifest'
else
  fail 'AC-1/2/4/6 normal daily snapshot'
fi

if grep -q "cron: '0 19 \* \* \*'" "$ROOT/.github/workflows/backup-to-google-drive.yml" \
  && grep -q 'workflow_dispatch:' "$ROOT/.github/workflows/backup-to-google-drive.yml" \
  && grep -q 'cancel-in-progress: false' "$ROOT/.github/workflows/backup-to-google-drive.yml" \
  && grep -q 'contents: read' "$ROOT/.github/workflows/backup-to-google-drive.yml"; then
  pass 'AC-1 schedule, manual dispatch, concurrency and minimal permissions are declared'
else
  fail 'AC-1 workflow declaration'
fi

if grep -q "RCLONE_RELEASE_VERSION: '1.75.0'" "$ROOT/.github/workflows/backup-to-google-drive.yml" \
  && ! grep -qE '^[[:space:]]+RCLONE_VERSION:' "$ROOT/.github/workflows/backup-to-google-drive.yml"; then
  pass 'AC-1 rclone release version avoids reserved RCLONE_VERSION environment variable'
else
  fail 'AC-1 rclone release version environment name'
fi

if grep -q 'sync --delete' "$ROOT/scripts/backup/backup-storage.sh"; then
  fail 'AC-3 Storage must not use deletion-propagating sync'
else
  pass 'AC-3 Storage implementation avoids deletion-propagating sync'
fi

if grep -q 'Google Driveのゴミ箱' "$ROOT/docs/backup/README.md" \
  && grep -q '400日' "$ROOT/docs/backup/README.md" \
  && grep -q '月1回' "$ROOT/docs/backup/README.md"; then
  pass 'AC-7 retention and independent monthly-copy operating procedure is documented'
else
  fail 'AC-7 retention documentation'
fi

if grep -q 'Issue/PR/コメント/Wiki/Releases/LFS/Actions Secrets' "$ROOT/docs/backup/README.md" \
  && grep -q 'clone --mirror' "$ROOT/scripts/backup/backup-git.sh"; then
  pass 'AC-4 Git mirror and non-Git scope are documented'
else
  fail 'AC-4 Git recovery scope'
fi

if grep -R -E --exclude='run-tests.sh' --exclude='create-age-key-usb.sh' '(AGE-SECRET-KEY-1|backup-key\.txt)' "$ROOT/.github" "$ROOT/scripts/backup" >/dev/null 2>&1; then
  fail 'AC-2 secret-key marker must not be required by automated backup'
else
  pass 'AC-2 automated backup does not require a secret key'
fi

if source "$ROOT/scripts/backup/lib.sh"; ! validate_safe_logical_path 'storage/a/..\\..\\escaped'; then pass 'SR-H1 Windows backslash traversal is rejected'; else fail 'SR-H1 traversal'; fi
if grep -q 'https://${SUPABASE_PROJECT_REF}.supabase.co' "$ROOT/scripts/backup/backup-storage.sh" && ! grep -q 'SUPABASE_STORAGE_URL' "$ROOT/scripts/backup/backup-storage.sh"; then pass 'SR-H2 host is derived from project ref'; else fail 'SR-H2 host allowlist'; fi
if grep -q 'pkeyutl -verify' "$ROOT/scripts/backup/inspect-backup.sh" && grep -q '_SUCCESS' "$ROOT/scripts/backup/inspect-backup.sh"; then pass 'SR-H3/L1 unsigned or incomplete snapshots are rejected'; else fail 'SR-H3/L1 signature'; fi
if grep -q 'type == "array"' "$ROOT/scripts/backup/backup-storage.sh" && ! grep -q 'SUPABASE_STORAGE_SERVICE_ROLE_KEY' "$ROOT/scripts/backup/backup-storage.sh"; then pass 'SR-M1/M4 Storage schema and credential-file controls'; else fail 'SR-M1/M4'; fi
if grep -q -- '--no-psqlrc' "$ROOT/scripts/backup/restore-db.sh" && ! grep -q 'target-db-url' "$ROOT/scripts/backup/restore-db.sh"; then pass 'SR-M3 URL argv is removed and psqlrc disabled'; else fail 'SR-M3'; fi
if grep -q 'backup-manual' "$ROOT/.github/workflows/backup-to-google-drive.yml" && grep -q 'backup-scheduled' "$ROOT/.github/workflows/backup-to-google-drive.yml" && grep -q 'GDRIVE_RESIDUAL_RISK_ACCEPTED' "$ROOT/scripts/backup/run-backup.sh"; then pass 'SR-M7/M8 event-separated Environment and residual-risk attestation required'; else fail 'SR-M7/M8'; fi
if grep -q 'supabase_linux_amd64.tar.gz' "$ROOT/.github/workflows/backup-to-google-drive.yml" && grep -q '7326f45a3354b6e44d948e4c6500ea9813247268887403ddfe9691ac2033f80e' "$ROOT/.github/workflows/backup-to-google-drive.yml"; then pass 'R-M1 fixed official Supabase CLI asset and SHA'; else fail 'R-M1 CLI pin'; fi
set +e
if command -v rg >/dev/null 2>&1; then
  rg -n 'BEGIN (.* )?PRIVATE KEY|AGE-SECRET-KEY|password=' "$ROOT" \
    --glob '!tests/**' --glob '!ops/**' --glob '!docs/**' --glob '!.git/**' \
    --glob '!**/node_modules/**' >/dev/null
  secret_scan_rc=$?
else
  grep -RIlE 'BEGIN (.* )?PRIVATE KEY|AGE-SECRET-KEY|password=' "$ROOT" \
    --exclude-dir=tests --exclude-dir=ops --exclude-dir=docs --exclude-dir=.git \
    --exclude-dir=node_modules >/dev/null
  secret_scan_rc=$?
fi
set -e
case "$secret_scan_rc" in
  0) fail 'R-M8 secret scan' ;;
  1) pass 'R-M8 repository code secret scan' ;;
  *) fail 'R-M8 secret scan could not complete' ;;
esac

if timeout 45 bash "$ROOT/tests/backup/storage-pagination.sh"; then
  pass 'R-L3 Storage dynamic pagination E2E suite'
else
  rc=$?
  [[ "$rc" == 124 ]] && fail 'R-L3 Storage dynamic pagination E2E suite (timed out)' || fail 'R-L3 Storage dynamic pagination E2E suite'
fi

if timeout 45 bash "$ROOT/tests/backup/e2e-real-crypto.sh"; then
  pass 'R-L3 filesystem Google Drive recovery E2E with real OpenSSL'
else
  rc=$?
  [[ "$rc" == 124 ]] && fail 'R-L3 filesystem Google Drive recovery E2E with real OpenSSL (timed out)' || fail 'R-L3 filesystem Google Drive recovery E2E with real OpenSSL'
fi

echo "Tests: passed=${PASS} failed=${FAIL}"
[[ "$FAIL" == 0 ]]
