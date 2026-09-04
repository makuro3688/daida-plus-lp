#!/usr/bin/env bash
# 実age/OpenSSLとfilesystem Google Drive mockでupload -> download -> inspectを通す。
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
temporary="$(mktemp -d)"
trap 'rm -rf -- "$temporary"' EXIT
mockbin="$temporary/bin"
mkdir -p "$mockbin"

# 親テストのmock PATHを引き継がず、検証済みage配置と標準ツールだけを使う。
if [[ -x /home/daida/.local/bin/age && -x /home/daida/.local/bin/age-keygen ]]; then
  age_bin_dir='/home/daida/.local/bin'
elif [[ -x /c/Users/user/age/age.exe && -x /c/Users/user/age/age-keygen.exe ]]; then
  age_bin_dir='/c/Users/user/age'
else
  echo 'E2E setup error: verified age installation was not found.' >&2
  exit 1
fi
e2e_system_path="${age_bin_dir}:/usr/local/bin:/c/Windows/System32/WindowsPowerShell/v1.0:/mingw64/bin:/usr/bin:/bin"
export PATH="$e2e_system_path"
for command_name in age-keygen openssl timeout; do
  command -v "$command_name" >/dev/null 2>&1 || {
    echo "E2E setup error: required command is unavailable: ${command_name}" >&2
    exit 1
  }
done
age-keygen --version >/dev/null
crypto_mode='real-age'
if ! age --version > "$temporary/age-version.log" 2>&1; then
  crypto_mode='mock-age-device-guard'
  echo 'SKIP: real age.exe is blocked by Windows Device Guard; continuing with mock encryption and real OpenSSL.' >&2
fi

cat > "$mockbin/rclone" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
if [[ "$1" == 'copyto' ]]; then
  source_file="$2"
  destination="$3"
  target="${MOCK_GDRIVE_ROOT}/${destination#gdrive:}"
  mkdir -p "$(dirname "$target")"
  cp "$source_file" "$target"
elif [[ "$1" == 'size' ]]; then
  target="${MOCK_GDRIVE_ROOT}/${2#gdrive:}"
  size="$(wc -c < "$target" | tr -d '[:space:]')"
  printf '{"count":1,"bytes":%s,"sizeless":0}\n' "$size"
elif [[ "$1" == 'delete' ]]; then
  exit 0
elif [[ "$1" == 'mkdir' ]]; then
  target="${MOCK_GDRIVE_ROOT}/${2#gdrive:}"
  mkdir -p "$target"
else
  echo "unexpected rclone invocation: $*" >&2
  exit 2
fi
EOF

cat > "$mockbin/docker" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
case " $* " in
  *' pg_dumpall '*) sql='CREATE ROLE "backup_test";' ;;
  *' --data-only '*) sql='INSERT INTO "public"."backup_test" VALUES (1);' ;;
  *' --schema-only '*) sql='CREATE TABLE "public"."backup_test" ("id" integer);' ;;
  *) exit 2 ;;
esac
printf '%s\n' "$sql"
EOF

cat > "$mockbin/git" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
if [[ "${1:-}" == clone && "${2:-}" == --mirror ]]; then
  destination="$4"
  mkdir -p "$destination/objects" "$destination/refs/heads"
  printf 'ref: refs/heads/main\n' > "$destination/HEAD"
  printf 'mock git object\n' > "$destination/objects/mock"
elif [[ "${1:-}" == --git-dir=* && "${2:-}" == fsck ]]; then
  [[ -s "${1#--git-dir=}/HEAD" ]]
else
  echo "unexpected git invocation: $*" >&2
  exit 2
fi
EOF
chmod +x "$mockbin/rclone" "$mockbin/docker" "$mockbin/git"

if [[ "$crypto_mode" != real-age ]]; then
  cat > "$mockbin/age" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
output=''; input=''
while [[ "$#" -gt 0 ]]; do
  case "$1" in
    -o) output="$2"; shift 2 ;;
    -r|-i) shift 2 ;;
    -d) shift ;;
    *) input="$1"; shift ;;
  esac
done
[[ -n "$output" && -f "$input" ]]
cp "$input" "$output"
EOF
  chmod +x "$mockbin/age"
  export PATH="$mockbin:$e2e_system_path"
else
  export PATH="$mockbin:$e2e_system_path"
fi

key_file="$temporary/age-secret-key.txt"
age-keygen -o "$key_file" >/dev/null 2> "$temporary/age-keygen.log"
age_public_key="$(sed -n 's/^# public key: //p' "$key_file")"
[[ "$age_public_key" == age1* ]] || {
  echo 'E2E setup error: age public key was not generated.' >&2
  exit 1
}
openssl genpkey -algorithm Ed25519 -out "$temporary/signing-private.pem" >/dev/null 2>&1
openssl pkey -in "$temporary/signing-private.pem" -pubout -out "$temporary/signing-public.pem" >/dev/null 2>&1

printf '%s\n' 'postgresql://backup-reader:test-only@test.invalid:5432/postgres' > "$temporary/supabase-db-url"
export AGE_PUBLIC_KEY="$age_public_key"
export GDRIVE_ROOT='DAIDA-BACKUPS'
export RCLONE_CONFIG_GDRIVE_CLIENT_ID='test-client-id.apps.googleusercontent.com'
export RCLONE_CONFIG_GDRIVE_CLIENT_SECRET='test-client-secret'
export RCLONE_CONFIG_GDRIVE_TOKEN='{"access_token":"test-only"}'
chmod 600 "$temporary/supabase-db-url"
export SUPABASE_DB_URL_FILE="$temporary/supabase-db-url"
export POSTGRES_CLIENT_IMAGE='postgres:17.11-alpine3.23@sha256:0000000000000000000000000000000000000000000000000000000000000000'
export BACKUP_SIGNING_KEY_FILE="$temporary/signing-private.pem"
export GDRIVE_RESIDUAL_RISK_ACCEPTED=true
export BACKUP_STORAGE_ENABLED=false
export GIT_BACKUP_SOURCE_URL='mock://repository'
export BACKUP_SNAPSHOT_ID='real-crypto-e2e'
export MOCK_GDRIVE_ROOT="$temporary/google-drive"

timeout 25 "$ROOT/scripts/backup/run-backup.sh" > "$temporary/run.log" 2>&1 || {
  rc=$?
  echo "real-crypto E2E: run-backup failed or timed out (exit=${rc})" >&2
  cat "$temporary/run.log" >&2
  exit 1
}

snapshot_parent="$MOCK_GDRIVE_ROOT/$GDRIVE_ROOT/snapshots/daily"
mapfile -t snapshots < <(find "$snapshot_parent" -mindepth 1 -maxdepth 1 -type d -print)
[[ "${#snapshots[@]}" == 1 ]] || {
  echo "real-crypto E2E: expected one daily filesystem Google Drive snapshot." >&2
  exit 1
}
snapshot_dir="${snapshots[0]}"

timeout 15 "$ROOT/scripts/backup/inspect-backup.sh" \
  "$snapshot_dir" "$key_file" "$temporary/signing-public.pem" "$temporary/inspected" \
  > "$temporary/inspect.log" 2>&1 || {
    rc=$?
    echo "real-crypto E2E: inspect-backup failed or timed out (exit=${rc})" >&2
    cat "$temporary/inspect.log" >&2
    exit 1
  }
for required in db/roles.sql db/schema.sql db/data.sql git/repository-mirror.tar.gz manifest.tsv; do
  [[ -s "$temporary/inspected/$required" ]] || {
    echo "real-crypto E2E: decrypted artifact is missing: ${required}" >&2
    exit 1
  }
done
tar -tzf "$temporary/inspected/git/repository-mirror.tar.gz" | grep -Fxq 'repository.git/HEAD'

expect_inspect_rejection() {
  local name="$1" candidate="$2" verify_key="${3:-$temporary/signing-public.pem}"
  local output="$temporary/rejected-${name}"
  if timeout 10 "$ROOT/scripts/backup/inspect-backup.sh" "$candidate" "$key_file" "$verify_key" "$output" > "$temporary/${name}.log" 2>&1; then
    echo "real-crypto E2E: ${name} unexpectedly passed inspection." >&2
    exit 1
  fi
}

copy_snapshot() {
  local name="$1" destination
  destination="$temporary/${name}/$(basename "$snapshot_dir")"
  mkdir -p "$(dirname "$destination")"
  cp -R "$snapshot_dir" "$destination"
  printf '%s\n' "$destination"
}

ciphertext_case="$(copy_snapshot ciphertext-tamper)"
ciphertext="$(find "$ciphertext_case/db" -type f -name '*.age' -print -quit)"
printf '\001' >> "$ciphertext"
expect_inspect_rejection ciphertext-tamper "$ciphertext_case"

root_case="$(copy_snapshot root-manifest-tamper)"
printf 'x' >> "$root_case/root-manifest.tsv"
expect_inspect_rejection root-manifest-tamper "$root_case"

openssl genpkey -algorithm Ed25519 -out "$temporary/other-private.pem" >/dev/null 2>&1
openssl pkey -in "$temporary/other-private.pem" -pubout -out "$temporary/other-public.pem" >/dev/null 2>&1
expect_inspect_rejection different-public-key "$snapshot_dir" "$temporary/other-public.pem"

marker_case="$(copy_snapshot success-marker-missing)"
rm -f -- "$marker_case/_SUCCESS"
expect_inspect_rejection success-marker-missing "$marker_case"

if [[ "$crypto_mode" == real-age ]]; then
  echo 'PASS: real age/OpenSSL upload-download-inspect and four tamper cases'
else
  echo 'PASS: mock-age/real-OpenSSL upload-download-inspect and four tamper cases'
fi
