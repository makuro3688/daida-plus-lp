# DAIDA+ 災害復旧バックアップ セキュリティ監査

監査日: 2026-08-30
監査対象: `.github/workflows/backup-to-r2.yml`、`scripts/backup/`、`docs/backup/`、`.gitignore`、`tests/backup/`
前提資料: `AGENTS.md`、`AI-HANDOFF.md`、`LESSONS.md`、`行動計画書_DAIDA災害復旧バックアップ_20260830.md`、`ops/backup/STATE.md`

## 結論

- 高: **3件**
- 中: **8件**
- 低: **2件**
- 総合判定: **差し戻し**

高が0件という合格条件を満たしません。特に、Windows復旧時のパストラバーサル、任意URLへのSupabase Service Role key送信、スナップショット作成元を証明する署名の欠如は、復旧用端末への任意ファイル作成、Supabase全権資格情報の漏洩、偽バックアップの正常判定につながります。

## 指摘

### SR-H1 Windows復旧時にバックスラッシュで出力先を脱出できる

【深刻度: 高】
【該当箇所: `scripts/backup/lib.sh:30`、`scripts/backup/inspect-backup.sh:21`】

【該当コード】

```bash
[[ -n "$path" && "$path" != /* && "$path" != *$'\n'* && "$path" != *$'\r'* && "$path" != *$'\t'* ]] || return 1
IFS='/' read -r -a pieces <<< "$path"
for piece in "${pieces[@]}"; do
  [[ -n "$piece" && "$piece" != '.' && "$piece" != '..' ]] || return 1
done
validate_storage_path "$logical" || backup_die 'manifest contains an unsafe path.'
encrypted="$snapshot_dir/${logical}.age"
decrypted="$output_dir/$logical"
```

【攻撃/事故と被害】
検査は`/`だけを区切りとしており、`..\`とバックスラッシュを許可します。WindowsのGit Bashではバックスラッシュもパス区切りとして処理されます。実測では`storage/example/..\..\escaped`が検査を通過し、意図した`output/storage/example`ではなく`output/escaped`が作成されました。Supabase Storageへ攻撃者がこの形式のオブジェクト名を登録できる場合、復号時に`output_dir`外へ任意内容の新規ファイルを作成できます。十分な`..\`を並べれば、復旧端末上の別ディレクトリへ到達します。

【具体的修正案】
リモートのbucket/object名をローカルパスへ直接使わず、各要素をbase64url等の安全な固定表現へ変換し、元の名前は署名対象マニフェストだけに保持してください。併せて`\`、C0制御文字、DEL、Windowsの予約名・末尾ドット/空白を拒否し、ファイル作成直前にWindowsネイティブの正規化後パスが`output_dir`配下であることを確認してください。`..\`、Unicode、予約名を含むWindows実機テストを追加します。

### SR-H2 `SUPABASE_STORAGE_URL`が任意ホストを許し、Service Role keyを送信する

【深刻度: 高】
【該当箇所: `scripts/backup/backup-storage.sh:16`】

【該当コード】

```bash
storage_api="${SUPABASE_STORAGE_URL%/}/storage/v1"
response="$(curl --fail --silent --show-error --max-time 120 --retry 2 \
  -X POST "${storage_api}/object/list/${bucket}" \
  -H "Authorization: Bearer ${SUPABASE_STORAGE_SERVICE_ROLE_KEY}" \
  -H "apikey: ${SUPABASE_STORAGE_SERVICE_ROLE_KEY}" \
  -H 'Content-Type: application/json' \
```

【攻撃/事故と被害】
`SUPABASE_STORAGE_URL`はGitHub Variableですが、形式・ホストの検証がありません。設定ミス、設定権限を持つアカウントの侵害、誤った復旧コマンドにより`https://attacker.example`等へ変更されると、RLSを迂回できるService Role keyがAuthorization/apikeyヘッダーでそのホストへ送られます。偽URLと偽キーを用いたテストで、スクリプトが`https://attacker.example/storage/v1/...`へ両ヘッダーを渡すことを確認しました。同じ問題は`restore-storage.sh:18-29`にもあります。

【具体的修正案】
外部通信より前にURLを正規化し、標準構成なら`https://<期待したproject-ref>.supabase.co`の完全一致だけを許可してください。userinfo、ポート、パス、query、fragment、IPアドレスは拒否します。カスタムドメインが必要な場合は、コードと別権限で管理する明示allowlistと期待project-refを照合します。バックアップと復元の双方に、非Supabaseホストへは通信せずヘッダーも送らない異常系テストを追加してください。

### SR-H3 age暗号化は作成元を証明せず、R2書込者が偽スナップショットを作れる

【深刻度: 高】
【該当箇所: `scripts/backup/inspect-backup.sh:19`】

【該当コード】

```bash
tail -n +5 "$output_dir/manifest.tsv" | while IFS=$'\t' read -r logical plain_bytes plain_hash encrypted_bytes encrypted_hash; do
  [[ -n "$logical" ]] || continue
  validate_storage_path "$logical" || backup_die 'manifest contains an unsafe path.'
  encrypted="$snapshot_dir/${logical}.age"
  decrypted="$output_dir/$logical"
  [[ -s "$encrypted" ]] || backup_die "encrypted artifact is missing: ${logical}"
  [[ "$(bytes_of "$encrypted")" == "$encrypted_bytes" && "$(sha256_of "$encrypted")" == "$encrypted_hash" ]] || backup_die "encrypted artifact checksum failed: ${logical}"
  age -d -i "$key_file" -o "$decrypted" "$encrypted"
  [[ -s "$decrypted" ]] || backup_die "decrypted artifact is empty: ${logical}"
  [[ "$(bytes_of "$decrypted")" == "$plain_bytes" && "$(sha256_of "$decrypted")" == "$plain_hash" ]] || backup_die "plaintext artifact checksum failed: ${logical}"
```

【攻撃/事故と被害】
ageは暗号文の改ざんを検知しますが、公開鍵を知る誰でも新しい正当なage暗号文を作れます。公開鍵は意図どおり公開情報であり、現在の検査は「復号でき、同じ暗号化マニフェストに書かれた自己申告ハッシュと一致すること」しか確認しません。R2 Object Read & Write資格情報が漏れた攻撃者は、偽のDB SQL・Gitアーカイブ・マニフェストを新しい時刻のprefixへ一式アップロードでき、検査を通過させられます。復元時には偽SQLを`psql`へ渡すため、データ改ざんに加えてpsqlメタコマンドを介した復旧端末上のコード実行へ発展し得ます。

【具体的修正案】
全artifactの論理名・サイズ・暗号文SHA-256・snapshot IDを正規化したルートマニフェストを、ageとは独立した署名鍵で署名してください。復旧側はリポジトリ外で信頼した公開署名鍵により署名を検証してから、復号・tar展開・SQL実行へ進みます。署名秘密鍵はR2資格情報から分離し、可能なら非抽出型KMSとGitHub Environment承認を使います。別事業者またはオフライン媒体へ署名済みルートハッシュを複製し、R2内だけの置換で履歴を作り直せないようにしてください。

### SR-M1 Storage APIのHTTP 200異常JSONを空バケットとして成功扱いする

【深刻度: 中】
【該当箇所: `scripts/backup/backup-storage.sh:29`、`scripts/backup/backup-storage.sh:50`】

【該当コード】

```bash
--data "$(jq -cn --arg prefix "$prefix" --argjson offset "$offset" '{prefix:$prefix,limit:1000,offset:$offset,sortBy:{column:"name",order:"asc"}}')")"
count="$(jq 'length' <<< "$response")"
[[ "$count" =~ ^[0-9]+$ ]] || backup_die "Storage API returned an invalid list for bucket: ${bucket}"
done < <(jq -r '.[] | [if (.id == null) then "directory" else "file" end, (.name | @base64)] | @tsv' <<< "$response")
(( count < 1000 )) && break
offset=$((offset + count))
```

【攻撃/事故と被害】
レスポンスが配列かを確認せず`length`だけを見ています。HTTP 200で`null`なら`length`は0になり、対象bucketを空として終了します。また、process substitution内の`jq`失敗は親シェルの`set -e`では確実に捕捉できません。偽curlで`null`を返したテストでは`backup-storage.sh`がexit 0となり、Storage artifactが0件のままinventoryを暗号化しました。ワークフロー全体もR2 uploadとheartbeatまで成功し、実際にはStorageが取れていない状態を正常と通知します。

【具体的修正案】
各ページを一旦ファイルへ保存し、`jq -e 'type == "array" and all(.[]; (type == "object") and (.name|type == "string"))'`相当でschemaを検証してから処理してください。`jq`の終了コードを通常のコマンドとして明示確認し、process substitutionへ失敗を隠さない構造にします。ページごとの件数、offset、最終件数、重複logical path、取得総数をマニフェストへ記録し、異常JSON・途中ページ失敗・1000/1001件・再帰prefixをテストしてください。

### SR-M2 必須artifactが0件でも「inspection completed」になる

【深刻度: 中】
【該当箇所: `scripts/backup/inspect-backup.sh:19`】

【該当コード】

```bash
tail -n +5 "$output_dir/manifest.tsv" | while IFS=$'\t' read -r logical plain_bytes plain_hash encrypted_bytes encrypted_hash; do
  [[ -n "$logical" ]] || continue
  validate_storage_path "$logical" || backup_die 'manifest contains an unsafe path.'
  encrypted="$snapshot_dir/${logical}.age"
  decrypted="$output_dir/$logical"
  [[ -s "$encrypted" ]] || backup_die "encrypted artifact is missing: ${logical}"
done
echo "inspection completed: ${output_dir}"
```

【攻撃/事故と被害】
マニフェストのversion/header、必須artifact、レコード数、重複、数値・SHA-256形式、余分な暗号文を検査していません。4行のheaderだけを復号するモックテストで、DB・Git artifactが1件もないのに`inspection completed`となることを再現しました。オペレーターが復元可能と誤認し、障害時に初めて必須ダンプ欠落へ気付きます。

【具体的修正案】
format/version/headerを完全一致で検査し、`db/roles.sql`、`db/schema.sql`、`db/data.sql`、`git/repository-mirror.tar.gz`を必須かつ各1件にしてください。Storageの有効/無効と期待bucket一覧も署名対象マニフェストへ明記し、有効時はinventoryを必須にします。サイズは正の整数、hashは64桁16進、logical pathは一意、snapshot IDはダウンロード元prefixと一致、マニフェスト外の`.age`は0件、と検証してから成功を表示します。

### SR-M3 DB復元の「隔離」確認が固定文字列だけで、任意DB URLを受け入れる

【深刻度: 中】
【該当箇所: `scripts/backup/restore-db.sh:7`】

【該当コード】

```bash
usage() { echo 'Usage: RESTORE_CONFIRM=restore-isolated-db restore-db.sh <decrypted-snapshot-dir> <target-db-url>' >&2; exit 64; }
[[ "$#" == 2 ]] || usage
[[ "${RESTORE_CONFIRM:-}" == 'restore-isolated-db' ]] || backup_die 'Set RESTORE_CONFIRM=restore-isolated-db after confirming the target is isolated.'
snapshot_dir="$1" target_db_url="$2"
for file in roles.sql schema.sql data.sql; do [[ -s "$snapshot_dir/db/$file" ]] || backup_die "required DB dump is missing: $file"; done
require_command psql
psql --single-transaction --variable=ON_ERROR_STOP=1 \
  --file "$snapshot_dir/db/roles.sql" \
```

【攻撃/事故と被害】
固定確認語は接続先を検証しません。オペレーターが本番URLを貼り付けても処理は開始され、SQL内容次第で本番のrole/schema/dataを変更します。`--single-transaction`は途中失敗の原子性を高めますが、「間違ったDBへ成功裏に全適用」を防ぎません。また`psql`は既定でローカルの`psqlrc`を読むため、復旧結果が端末設定にも左右されます。

【具体的修正案】
URLを構造解析して、事前登録した隔離project-ref/host/database/userのallowlistと完全一致させ、既知の本番project-refは明示拒否してください。接続後に隔離環境へ事前配置したランダムなmarkerを確認し、主要schemaが空または新規であることを読み取り検査してから、表示したhost/database固有の確認語を要求します。`psql --no-psqlrc`を追加し、DB URLはコマンド引数ではなく権限を絞った一時service file/credential storeから渡してください。

### SR-M4 Service Role keyとDB URLを子プロセスの引数へ載せている

【深刻度: 中】
【該当箇所: `scripts/backup/backup-storage.sh:24`】

【該当コード】

```bash
response="$(curl --fail --silent --show-error --max-time 120 --retry 2 \
  -X POST "${storage_api}/object/list/${bucket}" \
  -H "Authorization: Bearer ${SUPABASE_STORAGE_SERVICE_ROLE_KEY}" \
  -H "apikey: ${SUPABASE_STORAGE_SERVICE_ROLE_KEY}" \
  -H 'Content-Type: application/json' \
  --data "$(jq -cn --arg prefix "$prefix" --argjson offset "$offset" '{prefix:$prefix,limit:1000,offset:$offset,sortBy:{column:"name",order:"asc"}}')")"
```

【攻撃/事故と被害】
curlの`-H`値はプロセス引数です。同一runner/復旧端末の同一ユーザーで動く別プロセスは、実行中のコマンドラインからService Role keyを取得できます。`backup-db.sh:15`の`--db-url "$SUPABASE_DB_URL"`、`restore-db.sh:18`の`--dbname "$target_db_url"`、`restore-storage.sh:27-29`にも同種の露出があります。通常のGitHub-hosted runnerは短命ですが、実行時npm依存や侵害済みツールが同居するため、不要な露出です。

【具体的修正案】
curl headerは権限0600の一時config/header fileまたは標準入力から読み、argvへ値を出さないでください。DB資格情報は権限0600の一時PostgreSQL service/password fileまたは専用credential helperを使い、終了時に削除します。各外部コマンドは`env -u`等で不要なR2/GitHub/Supabase資格情報を継承させず、プロセスごとに必要最小の秘密だけを渡します。

### SR-M5 Windows復旧手順が秘密値をPowerShell履歴へ残す

【深刻度: 中】
【該当箇所: `docs/backup/restore.md:56`】

【該当コード】

```powershell
$env:SUPABASE_STORAGE_URL = 'https://<test-project>.supabase.co'
$env:SUPABASE_STORAGE_SERVICE_ROLE_KEY = '<test-project-service-role-key>'
$env:RESTORE_STORAGE_BUCKET_PREFIX = 'restore-'
$env:RESTORE_STORAGE_CONFIRM = 'restore-isolated-storage'
& 'C:\Program Files\Git\bin\bash.exe' scripts/backup/restore-storage.sh 'D:/DAIDA-recovery/decrypted'
Remove-Item Env:SUPABASE_STORAGE_URL, Env:SUPABASE_STORAGE_SERVICE_ROLE_KEY, Env:RESTORE_STORAGE_BUCKET_PREFIX, Env:RESTORE_STORAGE_CONFIRM
```

【攻撃/事故と被害】
実値へ置換した`$env:... = 'secret'`はPSReadLineの永続履歴へコマンド文字列ごと保存され得ます。後段の`Remove-Item Env:`は環境変数を消すだけで履歴を消しません。同じ問題がR2 Secret Access Key（同ファイル16-20行）とDB接続URL（42-47行）にもあり、PC利用者・マルウェア・バックアップソフトから資格情報を回収される可能性があります。文頭の「コマンド履歴に残さない」と手順が矛盾しています。

【具体的修正案】
秘密値をコマンドへ貼らせず、Windows SecretManagement、資格情報マネージャー、パスワードマネージャーCLI、または`Read-Host -AsSecureString`による非履歴入力を使うラッパーを用意してください。DB URLも同様に入力し、復旧後は一時credential file、環境変数、PowerShell変数を削除します。平文復号先はBitLocker等で暗号化した使い捨てボリュームとし、訓練後にボリュームごと破棄する手順を追加してください。

### SR-M6 実行時npm取得にcontent integrity固定がなく、全ジョブ秘密を継承する

【深刻度: 中】
【該当箇所: `.github/workflows/backup-to-r2.yml:30`、`scripts/backup/backup-db.sh:15`】

【該当コード】

```yaml
AWS_ACCESS_KEY_ID: ${{ secrets.R2_ACCESS_KEY_ID }}
AWS_SECRET_ACCESS_KEY: ${{ secrets.R2_SECRET_ACCESS_KEY }}
AWS_DEFAULT_REGION: auto
SUPABASE_DB_URL: ${{ secrets.SUPABASE_DB_URL }}
SUPABASE_STORAGE_URL: ${{ vars.SUPABASE_URL }}
SUPABASE_STORAGE_SERVICE_ROLE_KEY: ${{ secrets.SUPABASE_SERVICE_ROLE_KEY }}
```

```bash
npx --yes "supabase@${SUPABASE_CLI_VERSION}" db dump --db-url "$SUPABASE_DB_URL" -f "$output" "$@"
```

【攻撃/事故と被害】
バージョン番号は固定されていますが、`npx`はworkflow実行時にnpm registryから実行物を取得し、lockfileのintegrityまたは別途検証したSHA-256を使いません。さらに秘密がjob-level `env`にあるため、Supabase CLIとそのインストール処理は、DB URLだけでなくR2秘密鍵、Storage Service Role key、GitHub token、heartbeat URLも継承します。registry・パッケージ・取得経路・transitive install scriptの侵害時に、全バックアップ資格情報が同時に漏れます。

【具体的修正案】
Supabase CLIの公式バイナリを固定URLから取得して公開checksum/署名を検証するか、事前レビューしたコンテナimage digestへ固定してください。npm方式を残すなら、専用package-lockのintegrityをレビューして`npm ci`で再現可能にします。どの場合も、DB dumpプロセスからR2、Service Role、GitHub、heartbeatの環境変数を除去し、工程ごとに秘密を分離してください。

### SR-M7 手動実行で任意branchを選べ、Environment保護なしでrepo Secretsを使う

【深刻度: 中】
【該当箇所: `.github/workflows/backup-to-r2.yml:3`、`.github/workflows/backup-to-r2.yml:33`】

【該当コード】

```yaml
on:
  # GitHub Actions の cron は UTC。19:00 UTC = 毎日 04:00 JST。
  schedule:
    - cron: '0 19 * * *'
  workflow_dispatch:
SUPABASE_DB_URL: ${{ secrets.SUPABASE_DB_URL }}
SUPABASE_STORAGE_URL: ${{ vars.SUPABASE_URL }}
SUPABASE_STORAGE_SERVICE_ROLE_KEY: ${{ secrets.SUPABASE_SERVICE_ROLE_KEY }}
SUPABASE_STORAGE_BUCKETS: ${{ vars.SUPABASE_STORAGE_BUCKETS }}
BACKUP_STORAGE_ENABLED: ${{ vars.BACKUP_STORAGE_ENABLED || 'false' }}
```

【攻撃/事故と被害】
GitHubの`workflow_dispatch`は書込み権限者がbranchを選択して実行できますが、このjobには`environment:`がなく、秘密はrepository-levelです。書込み権限アカウントが侵害された場合、攻撃者は自分のbranchでworkflowを変更して手動実行し、既定branchの保護を通らずにDB URL、Service Role、R2資格情報を外部送信できます。`contents: read`は`GITHUB_TOKEN`を絞るだけで、外部Secretsの漏洩を防ぎません。

【具体的修正案】
秘密を保護されたGitHub Environmentへ移し、jobへ`environment: backup-production`を指定してください。Environmentのdeployment branchを既定branchだけに限定し、手動実行にはrequired reviewerを設定します。repository-levelには本番秘密を残さず、branch側が`environment:`を削除しても秘密を取得できない構成にしてください。運用者が1名だけの場合も、アカウント侵害時の追加防壁として有効です。

### SR-M8 R2書込み資格情報は削除・上書き可能で、Bucket Lockが未検証の外部前提

【深刻度: 中】
【該当箇所: `docs/backup/README.md:28`】

【該当コード】

```markdown
R2で専用バケット（例: `daida-offsite-backup`）を作ります。ワークフロー用トークンは**Object Read & Write**を、そのバケットだけに限定します。`Admin Read & Write`、バケット作成・削除、Bucket Lock・Lifecycle設定変更の権限は付与しません。

R2のバケット側で次を別途設定します。

| プレフィックス | Bucket Lock保持 | Lifecycle削除 | 用途 |
|---|---:|---:|---|
| `daida-plus/snapshots/daily/` | 90日 | 90日経過後 | 毎日の復旧点 |
| `daida-plus/snapshots/monthly/` | 400日 | 400日経過後 | 毎月1日の長期復旧点 |

Bucket Lockは保持期間中の削除・上書きを防ぎ、Lifecycleより優先します。
```

【攻撃/事故と被害】
Object Read & Write資格情報は対象bucket内の既存objectを削除・上書きできます。日時別unique keyは通常実行の衝突を避けますが、資格情報漏洩時の削除を防ぎません。防御は外部で設定するBucket Lockに依存し、今回のオフライン実装からは設定済みか確認できません。ロック前にworkflowを有効化すると、Supabase/GitHubとR2資格情報を同時に侵害された際に全復旧点を失い得ます。

【具体的修正案】
本番有効化の必須ゲートとして、daily/monthly両prefixのBucket Lock rule、保持日数、Lifecycle、管理者分離をCloudflare画面と読み取りAPIで二者確認し、結果を復旧台帳へ記録してください。可能なら、workflowはPut専用のCloudflare Worker/APIを経由し、削除・既存key上書きをサーバー側で拒否します。別Cloudflareアカウント/別事業者または暗号化USBへの月次コピーを、初回バックアップ後から実施します。この中リスクを残す場合はユーザーの明示受容が必要です。

### SR-L1 部分アップロードを示す完了markerがなく、不完全prefixが残る

【深刻度: 低】
【該当箇所: `scripts/backup/lib.sh:68`、`scripts/backup/run-backup.sh:74`】

【該当コード】

```bash
while IFS= read -r -d '' encrypted_file; do
  relative="${encrypted_file#"${BACKUP_STAGE_DIR}/"}"
  object="${R2_PREFIX}/snapshots/${class}/${BACKUP_SNAPSHOT_NAME}/${relative}"
  aws s3 cp "$encrypted_file" "s3://${R2_BUCKET}/${object}" \
    --endpoint-url "$R2_ENDPOINT" --only-show-errors
done < <(find "$BACKUP_SNAPSHOT_DIR" -type f -name '*.age' -print0 | sort -z)
if [[ -n "${BACKUP_HEARTBEAT_URL:-}" ]]; then
  curl --fail --silent --show-error --max-time 20 --retry 2 -X POST "$BACKUP_HEARTBEAT_URL" >/dev/null
fi
```

【攻撃/事故と被害】
途中の`aws s3 cp`失敗ではworkflowとheartbeatは正しく失敗しますが、それ以前にupload済みのobjectはprefixへ残ります。R2画面で時刻だけを見た担当者が不完全prefixを選ぶと、ダウンロード後の検査まで欠落に気付きません。R2に孤立multipart uploadが残る可能性もあります。

【具体的修正案】
全objectのuploadとHEAD/size検証後、署名対象snapshot IDを含む`_SUCCESS` markerを最後に作成してください。復旧手順とdownload scriptはmarkerがあり、署名・manifest検査に成功したprefixだけを候補にします。不完全prefixとabort incomplete multipart uploadのLifecycleも設定します。

### SR-L2 月次判定がUTCのため、JST月初ではなく原則2日04:00に作られる

【深刻度: 低】
【該当箇所: `scripts/backup/run-backup.sh:69`】

【該当コード】

```bash
upload_snapshot_to_prefix daily
if [[ "$(date -u '+%d')" == '01' ]]; then
  upload_snapshot_to_prefix monthly
fi
```

【攻撃/事故と被害】
workflowはUTC 19:00（JST翌日04:00）に動きますが、月次判定はUTC日付です。JST 9月1日04:00はUTC 8月31日19:00なのでmonthlyにならず、UTC 9月1日19:00＝JST 9月2日04:00がmonthlyになります。長期保存自体は月1回作られるため直ちに復旧不能ではありませんが、手順書の「毎月1日」と実態がずれ、月初訓練・保持確認を誤らせます。

【具体的修正案】
`TZ=Asia/Tokyo date '+%d'`で運用日を判定するか、scheduleと判定条件をUTC基準として文書も一致させてください。月末/月初の固定時刻テストを追加します。

## 良好だった点

- `actions/checkout`はフルcommit SHAへ固定されています。
- age v1.3.2 Linux amd64 tarballのSHA-256 `cbe240...ac10`は、2026-08-30に公式GitHub Release掲載値と一致することを確認しました。
- workflowの`permissions`は`contents: read`だけです。
- age秘密鍵を自動処理へ要求せず、秘密鍵の典型ファイル名を`.gitignore`へ追加しています。対象コードから秘密鍵の直書きは見つかりませんでした。
- `set -Eeuo pipefail`、非空検査、個別age暗号化、日時+run IDのunique prefix、削除伝播型Storage syncの不使用、Git tokenをURLへ埋め込まないHTTP header方式は妥当です。
- Git mirrorにIssue/PR/Wiki/Releases/LFS/Actions Secrets等が含まれない境界は文書化されています。

## 独立実行した検証

### 成功

```text
Bash構文検査: PASS
tests/backup/run-tests.sh: passed=17 failed=0
git diff --check: whitespace error 0（既存CRLF警告のみ）
age v1.3.2 tarball SHA-256: 公式Release掲載値と一致
```

### 追加攻撃テスト

```text
Windows Git Bash path probe:
  validator=ACCEPTED
  想定 output/storage/example 配下に対し、実際は output/escaped を作成

Storage endpoint/response probe:
  SUPABASE_STORAGE_URL=https://attacker.example を受理
  Authorization/apikeyのfake Service Role keyを同hostへ渡した
  response=null でも script_exit=0

Empty manifest probe:
  artifact record 0件でも inspection completed
```

## 未検証境界

- 本物のSupabase、Storage、R2、GitHub Actionsへの接続は行っていません。R2 Bucket Lock/Lifecycle、API token実権限、Environment/branch protection、heartbeatの30時間alertは未検証です。
- `shellcheck`と`actionlint`はローカルに存在せず未実行です。
- バックアップ用の`package.json`/lockfileがなく、`supabase@2.67.1`は実行時取得のため、再現可能な`npm audit`を実施できませんでした。既知脆弱性は未検証であり、記憶によるCVE断定はしていません。
- 実データ量、Storage 1000/1001件ページネーション、同時更新、深いprefix、Unicode/Windows予約名、Git巨大履歴、実age復号、実Postgres/Supabase隔離復元は未検証です。
- GitHub mirrorのGit履歴・branch・tagは設計対象ですが、LFS実体、Wiki、Issue/PR、Actions Secrets、ローカル未commitは設計どおり対象外です。

## 総合判定

**差し戻し。** SR-H1〜H3を修正し、高0件にしてください。SR-M1〜M8は修正、または残すものについてユーザーの明示受容が必要です。修正後は本報告の追加攻撃テストを自動テストへ昇格し、別のセキュリティ監査担当が再実行して判定してください。
