#!/usr/bin/env bash
set -Eeuo pipefail

umask 077
export PATH="$HOME/.local/bin:$PATH"

USB_ROOT="${1:-/mnt/d}"
case "$USB_ROOT" in
  /mnt/[a-zA-Z]) ;;
  *)
    echo 'Usage: create-age-key-usb.sh /mnt/<usb-drive-letter>' >&2
    exit 64
    ;;
esac

command -v age >/dev/null
command -v age-keygen >/dev/null
test -d "$USB_ROOT" || { echo "USB mount not found: $USB_ROOT" >&2; exit 66; }

TARGET_DIR="$USB_ROOT/DAIDA-BACKUP-KEYS"
STAGE_DIR="$USB_ROOT/.DAIDA-BACKUP-KEYS.tmp.$$"

test ! -e "$TARGET_DIR" || {
  echo "Refusing to overwrite existing directory: $TARGET_DIR" >&2
  exit 73
}
test ! -e "$STAGE_DIR" || { echo "Unexpected staging path exists: $STAGE_DIR" >&2; exit 73; }

TEMP_DIR="$(mktemp -d)"

cleanup() {
  rm -f -- "$TEMP_DIR/backup-key.txt" "$TEMP_DIR/recovered-key.txt"
  rmdir -- "$TEMP_DIR" 2>/dev/null || true
  if [[ -d "$STAGE_DIR" ]]; then
    rm -f -- "$STAGE_DIR/backup-key.txt.age" "$STAGE_DIR/AGE_PUBLIC_KEY.txt" \
      "$STAGE_DIR/backup-key.txt.age.sha256" "$STAGE_DIR/README.txt"
    rmdir -- "$STAGE_DIR" 2>/dev/null || true
  fi
}
trap cleanup EXIT

mkdir -- "$STAGE_DIR"
age-keygen -o "$TEMP_DIR/backup-key.txt" >/dev/null 2>&1
PUBLIC_KEY="$(age-keygen -y "$TEMP_DIR/backup-key.txt")"

cat <<'EOF'

USBへ保存する秘密鍵を、パスフレーズで暗号化します。
この後に入力するパスフレーズは画面に表示されません。
パスフレーズをこのUSB内やAIチャットへ保存しないでください。

EOF

age --encrypt --passphrase \
  --output "$STAGE_DIR/backup-key.txt.age" \
  "$TEMP_DIR/backup-key.txt"

printf '%s\n' "$PUBLIC_KEY" > "$STAGE_DIR/AGE_PUBLIC_KEY.txt"
(
  cd "$STAGE_DIR"
  sha256sum backup-key.txt.age > backup-key.txt.age.sha256
)

cat <<'EOF' > "$STAGE_DIR/README.txt"
DAIDA+ backup recovery key

- backup-key.txt.age: パスフレーズで暗号化されたage秘密鍵
- AGE_PUBLIC_KEY.txt: GitHub Variableへ登録する公開鍵（公開可）
- backup-key.txt.age.sha256: 暗号化ファイルの破損確認用

復号パスフレーズは、このUSBとは別のパスワードマネージャーまたは紙へ保管してください。
秘密鍵の平文をUSB、GitHub、リポジトリ、AIチャットへ保存しないでください。
EOF

cat <<'EOF'

確認のため、同じパスフレーズをもう一度入力してください。

EOF
age --decrypt \
  --output "$TEMP_DIR/recovered-key.txt" \
  "$STAGE_DIR/backup-key.txt.age"

cmp --silent "$TEMP_DIR/backup-key.txt" "$TEMP_DIR/recovered-key.txt"
test "$(age-keygen -y "$TEMP_DIR/recovered-key.txt")" = "$PUBLIC_KEY"

mv -- "$STAGE_DIR" "$TARGET_DIR"
STAGE_DIR=''
sync

printf '\n作成と復号確認に成功しました: %s\n' "$TARGET_DIR"
printf '公開鍵は AGE_PUBLIC_KEY.txt にあります。秘密鍵の平文は保存していません。\n'
