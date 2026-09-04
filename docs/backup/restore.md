# DAIDA+ 復旧手順

この手順は、まず隔離環境で復旧できることを確かめるためのものです。秘密鍵・接続文字列をチャット、コマンド履歴、リポジトリに残さないでください。

## 0. 判断と準備

1. 誤削除・侵害時は、元アカウントの資格情報を無条件に信用せず、必要ならローテーションします。
2. 専用Google Driveから、障害直前より前の`daily/<timestamp>`または`monthly/<timestamp>`の**同一スナップショット一式**を空のローカルフォルダへダウンロードします。
3. インターネット分離または別アカウントに、検査用のPostgres/Supabaseプロジェクトを用意します。本番URLは使いません。
4. `age`、`psql`、Gitを用意します。Windowsの実行制御で`age.exe`が拒否される端末では、Device Guardを解除せず、WSL2上の公式`age`を使います。

## 1. ダウンロード

専用Googleアカウントへrcloneのread-only接続を作り、選択したフォルダをローカルへコピーします。`<...>`は実値に置換しますが、OAuth tokenを画面共有や記録へ出しません。

PowerShell履歴へ秘密値を貼らないでください。rcloneの設定ファイルは本人だけが読めるACLにし、復号先はBitLocker暗号化済みの使い捨てボリューム（例: `R:`）に限定します。訓練後は一時設定と復号先を破棄します。

ダウンロード前に`_SUCCESS`、`root-manifest.tsv`、`root-manifest.sig`が同じprefixにあることを確認します。これらがないprefixは途中失敗なので選びません。

復旧用接続はread-onlyとし、バックアップ書込み用OAuth tokenとは別にします。

## 2. 復号・完全性検査

秘密鍵はリポジトリの外部に保管し、出力先は新規かつ空の隔離フォルダにします。

### 推奨: WSL2で検査

WindowsのドライブはWSLから`C:`=`/mnt/c`、`D:`=`/mnt/d`として参照できます。秘密鍵をWSLのホームやリポジトリへコピーせず、暗号化USBまたはBitLocker保護ドライブ上のファイルを直接指定します。

```bash
export PATH="$HOME/.local/bin:$PATH"
cd /mnt/c/Users/user/Documents/GitHub/daida-plus-lp
bash scripts/backup/inspect-backup.sh \
  '/mnt/d/DAIDA-recovery/<timestamp-snapshot-id>' \
  '/mnt/d/DAIDA-backup-keys/backup-key.txt' \
  '/mnt/d/DAIDA-backup-keys/backup-signing-public.pem' \
  '/mnt/d/DAIDA-recovery/decrypted'
```

このPCでは、公式`age` v1.3.2のSHA-256をGitHub Actionsと同じ値で検証してWSLへ導入し、一時鍵による実暗号化・復号・平文一致を確認済みです。

### Windows版ageが許可されている端末

```powershell
& 'C:\Program Files\Git\bin\bash.exe' scripts/backup/inspect-backup.sh `
  'D:/DAIDA-recovery/<timestamp-snapshot-id>' `
  'D:/DAIDA-backup-keys/backup-key.txt' `
  'D:/DAIDA-backup-keys/backup-signing-public.pem' `
  'D:/DAIDA-recovery/decrypted'
```

この処理は暗号文・平文両方のサイズとSHA-256をマニフェストと照合します。失敗した場合は復元を続けず、別スナップショットの検査、Google Driveからのダウンロード完全性、鍵の取り違えを確認します。

## 3. 隔離DBへ復元

新規Supabaseプロジェクトまたは隔離Postgresに、復旧専用service file（0600）と、事前作成済みのランダムmarkerを用意します。接続URLをコマンド引数やPowerShell履歴へ貼り付けません。`restore-db.sh`はservice fileで接続し、allowlistされたDB/userとmarker queryが一致しなければ停止します。

```powershell
$env:RESTORE_CONFIRM = 'restore-isolated-db'
$env:RESTORE_DB_SERVICE_FILE = 'R:/pg_service.conf' # ACLを本人だけに限定
$env:RESTORE_TARGET_PROJECT_REF = '<20-character-isolated-project-ref>'
$env:RESTORE_PRODUCTION_PROJECT_REF = '<20-character-production-project-ref>'
# service fileの[daida_restore]は host=db.<target-ref>.supabase.co / dbname=postgres / user=postgres / port=5432 / sslmode=require の各1行だけにする
# marker値はRead-Host -AsSecureString等で非履歴入力し、使い捨てenvへ展開する（RESTORE_DB_MARKER_VALUE）
& 'C:\Program Files\Git\bin\bash.exe' scripts/backup/restore-db.sh 'R:/decrypted'
```

`roles.sql` → `schema.sql` → `data.sql`の順で単一トランザクション復元します。Supabaseでの復元後は、Realtime publicationを必要なテーブルへ再有効化します。Auth/Storageスキーマを独自に変更している場合、差分SQLを別途適用します。公式の注意点: [Supabase CLI restore](https://supabase.com/docs/guides/platform/migrating-within-supabase/backup-restore)。

## 4. Storageを隔離バケットへ復元（使用時）

Storageバケットを先に、`restore-<元バケット名>`のような本番と異なる名前で作ります。ポリシーとバケット設定は`recovery-inventory.md`を参照して手動再作成します。

```powershell
$env:RESTORE_SUPABASE_PROJECT_REF = '<20-character-test-project-ref>'
$env:RESTORE_STORAGE_CURL_CONFIG = 'R:/storage-curl.conf' # keyは0600相当ACLのconfig内にだけ置く
$env:RESTORE_STORAGE_BUCKET_PREFIX = 'restore-'
$env:RESTORE_STORAGE_CONFIRM = 'restore-isolated-storage'
& 'C:\Program Files\Git\bin\bash.exe' scripts/backup/restore-storage.sh 'D:/DAIDA-recovery/decrypted'
Remove-Item Env:RESTORE_SUPABASE_PROJECT_REF, Env:RESTORE_STORAGE_CURL_CONFIG, Env:RESTORE_STORAGE_BUCKET_PREFIX, Env:RESTORE_STORAGE_CONFIRM
```

このスクリプトは同名本番バケットを対象にできないよう、ハイフンで終わる隔離用接頭辞を必須にしています。画像のContent-Type等のメタデータを利用する場合は、検証後に必要なメタデータを手動確認します。

## 5. Gitを復元

```powershell
& 'C:\Program Files\Git\bin\bash.exe' scripts/backup/restore-git.sh `
  'D:/DAIDA-recovery/decrypted' `
  'D:/DAIDA-recovery/daida-plus-lp-restored'
```

復元後、`git log --all`、`git fsck --full`、必要なタグ・ブランチを確認します。Issue/PR/Wiki/Secrets等はGitに含まれないため、復旧台帳から再設定します。

## 6. 合格条件と定期訓練

- DBへ接続して主要テーブル・Authレコードを確認できる。
- Storage利用時は、隔離バケットでサンプルファイルを取得できる。
- Git履歴・タグ・ブランチが存在し、`git fsck --full`が成功する。
- Auth、Edge Functions、Realtime、DNS、Render、Resendなどの不足設定を復旧台帳と突き合わせる。

月1回は「復号・検査」、3か月ごとは隔離SupabaseへのDB/Storage/Git復旧訓練を実施し、日付・担当・結果を運用記録へ残します。
