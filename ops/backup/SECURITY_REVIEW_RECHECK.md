# DAIDA+ 災害復旧バックアップ 是正後セキュリティ再監査

監査日: 2026-08-30
監査方式: 実装変更なし。読み取り、一次情報との照合、Bash構文検査、モック攻撃、実OpenSSL署名検証のみ
対象: `.github/workflows/backup-to-r2.yml`、`.gitignore`、`scripts/backup/`、`docs/backup/`、`tests/backup/`、`ops/backup/STATE.md`

## 結論

- 高: **0件**
- 中: **8件**（うち外部運用前提2件）
- 低: **3件**
- 総合判定: **差し戻し**

初回の高3件は、パスのSHA-256化、Supabase Project Refからのホスト導出、Ed25519署名と外部信頼鍵によって解消しています。一方、現在のワークフローはSupabase CLIの404で開始できず、仮にそこを通してもR2上の階層と検査側が不一致です。さらに階層を補正した再現でもroot manifest件数検査に必ず失敗しました。現状を「復旧可能なバックアップ」として有効化してはいけません。

## 初回指摘ごとの判定

| 初回ID | 判定 | 実コード・再実行結果 |
|---|---|---|
| SR-H1 | **解消** | Storage objectは`sha256(object)`名で保存され、復号先logical pathはASCII許可リストへ限定。Windows `storage/a/..\\..\\escaped`は現テストでも拒否。元名はbase64 inventoryだけに残る。 |
| SR-H2 | **解消** | `SUPABASE_STORAGE_URL`をコードから除去し、`^[a-z0-9]{20}$`のRefから`https://<ref>.supabase.co`を導出。公式Management APIのProject Ref例も20文字。任意hostを入力する経路は消滅。 |
| SR-H3 | **解消** | root manifestはsnapshot IDと全`.age`のSHA-256をソートして署名。実OpenSSLで正規署名は受理、root 1byte変更と別公開鍵は拒否。公開鍵はR2外を必須とする。 |
| SR-M1 | **未解消** | `null`はexit 64で拒否するよう改善。ただし空配列は`jq -e '.[]'`のexit 4で失敗し、非空時もlist JSON/TSVが平文残存検査に引っかかる。1000/1001件、重複bucket、途中変動の自動テストなし。R-M4参照。 |
| SR-M2 | **未解消** | header、必須artifact、重複、型、余分な`.age`は厳格化され、空manifestはexit 64。ただし実生成物はR2階層不一致とroot/manifest件数不一致で正常snapshotまで拒否する。R-M2、R-M3参照。 |
| SR-M3 | **未解消** | DB URL argv廃止、`--no-psqlrc`、service file、identity/markerは追加。ただしWindowsでmode検査が通らず、allowlistは実hostではなくファイル内文字列をgrepするだけ。既知本番host拒否もない。R-M5参照。 |
| SR-M4 | **解消** | Storage keyは0600 curl config、DB URLは0600 service fileへ移り、argv露出は解消。workflowの`always()` cleanupもある。不要secretの子process継承は低リスクとしてR-L2に残す。 |
| SR-M5 | **解消** | Windows手順から秘密値の直貼り例を削除し、Credential Manager/パスワードマネージャー、BitLocker使い捨て領域、一時credential fileを指示。 |
| SR-M6 | **未解消** | `npx`は廃止したが、固定Release asset名が実在せず404。固定取得方式として動作していない。R-M1参照。 |
| SR-M7 | **未解消** | jobへ`environment: backup-production`は追加。ただしbranch policyは外部未設定で、文書の「手動だけrequired reviewer・scheduleは承認不要」は単一Environmentでは両立しない。R-M6参照。 |
| SR-M8 | **未解消（外部前提）** | `R2_RETENTION_LOCK_CONFIRMED=true`は自己申告文字列で、R2 LockをAPI確認しない。実Lock未確認のためユーザー受容または実設定確認が必要。R-M7参照。 |
| SR-L1 | **未解消** | `_SUCCESS`は最後に作成し検査側も必須化。marker差替えだけでは署名済みsnapshot IDを回避できない。ただしHEAD/size検証なし、かつ実upload階層が誤っている。R-M2、R-L1参照。 |
| SR-L2 | **解消** | 月次判定は`TZ=Asia/Tokyo date '+%d'`へ変更済み。 |

## 中リスク指摘

### R-M1 Supabase CLI固定archiveのURLが404で、全バックアップが開始前に失敗する

【状態】新規問題 / SR-M6未解消
【該当箇所】`.github/workflows/backup-to-r2.yml:64-73`

```yaml
- name: Install and verify Supabase CLI
  shell: bash
  run: |
    set -Eeuo pipefail
    test -n "${SUPABASE_CLI_TARBALL_SHA256:-}" || { echo 'SUPABASE_CLI_TARBALL_SHA256 is required.' >&2; exit 64; }
    curl --fail --location --retry 3 --proto '=https' --tlsv1.2 --output supabase.tar.gz "https://github.com/supabase/cli/releases/download/v${SUPABASE_CLI_VERSION}/supabase_${SUPABASE_CLI_VERSION}_linux_amd64.tar.gz"
    echo "${SUPABASE_CLI_TARBALL_SHA256}  supabase.tar.gz" | sha256sum --check --status
```

【攻撃/事故】公式Releaseへ実アクセスした結果、コードの`supabase_2.67.1_linux_amd64.tar.gz`はHTTP **404**、実在する`supabase_linux_amd64.tar.gz`はHTTP **200**でした。公式checksum assetの正しいSHA-256は`7326f45a3354b6e44d948e4c6500ea9813247268887403ddfe9691ac2033f80e`です。現在はschedule/手動の双方がDB取得前に止まり、復旧点が1件も作られません。[Supabase CLI v2.67.1 Release](https://github.com/supabase/cli/releases/tag/v2.67.1)、[公式checksums](https://github.com/supabase/cli/releases/download/v2.67.1/supabase_2.67.1_checksums.txt)

【修正案】asset名を`supabase_linux_amd64.tar.gz`へ直し、公式SHAをworkflowへliteral固定してください。ダウンロード、SHA照合、展開後`supabase --version == 2.67.1`までをテストしてください。

### R-M2 R2へ`snapshot/`を余分に付け、生成直後のsnapshotを検査できない

【状態】新規問題 / SR-M2・SR-L1未解消
【該当箇所】`scripts/backup/lib.sh:83-90`、`scripts/backup/inspect-backup.sh:9-10`

```bash
while IFS= read -r -d '' encrypted_file; do
  relative="${encrypted_file#"${BACKUP_STAGE_DIR}/"}"
  object="${R2_PREFIX}/snapshots/${class}/${BACKUP_SNAPSHOT_NAME}/${relative}"
  aws s3 cp "$encrypted_file" "s3://${R2_BUCKET}/${object}" \
    --endpoint-url "$R2_ENDPOINT" --only-show-errors
done < <(find "$BACKUP_SNAPSHOT_DIR" -type f -print0 | sort -z)
```

```bash
snapshot_dir="$1" key_file="$2" verify_key="$3" output_dir="$4"
[[ -d "$snapshot_dir" && -f "$snapshot_dir/manifest.tsv.age" && -f "$snapshot_dir/root-manifest.tsv" && -f "$snapshot_dir/root-manifest.sig" && -f "$snapshot_dir/_SUCCESS" ]] || backup_die 'snapshot is missing a required manifest, signature, or _SUCCESS marker.'
```

【攻撃/事故】`encrypted_file`は`$BACKUP_STAGE_DIR/snapshot/...`ですが、stage rootを除いているためR2 keyは`<snapshot-id>/snapshot/manifest.tsv.age`になります。`_SUCCESS`だけは`<snapshot-id>/_SUCCESS`です。実run-backupをR2コピーmockで実行し、そのままinspectへ渡すとexit 64、`snapshot is missing a required manifest...`を再現しました。workflowはuploadとheartbeatを成功扱いするのに、手順どおりの復旧は不能です。

【修正案】relativeは`BACKUP_SNAPSHOT_DIR`から切り、R2 prefix直下へmanifest/root/sig/artifactを揃えてください。mockは引数行数ではなくR2側ディレクトリを実際に再構成し、生成→upload→download→inspectを一続きで検証してください。

### R-M3 root manifestと暗号化manifestの件数条件が構造上成立しない

【状態】新規問題 / SR-M2未解消
【該当箇所】`scripts/backup/run-backup.sh:67-75`、`scripts/backup/inspect-backup.sh:57-59`

```bash
record_artifact 'manifest.tsv' "$BACKUP_MANIFEST_TSV"
root="$BACKUP_SNAPSHOT_DIR/root-manifest.tsv"
{ printf 'format\tbackup-root-v1\nsnapshot\t%s\n' "$BACKUP_SNAPSHOT_NAME"; find "$BACKUP_SNAPSHOT_DIR" -type f -name '*.age' -print0 | sort -z | while IFS= read -r -d '' f; do printf '%s\t%s\n' "${f#"$BACKUP_SNAPSHOT_DIR/"}" "$(sha256_of "$f")"; done; } > "$root"
openssl pkeyutl -sign -rawin -inkey "$BACKUP_SIGNING_KEY_FILE" -in "$root" -out "$BACKUP_SNAPSHOT_DIR/root-manifest.sig"
```

```bash
for item in $required; do [[ -n "${logical_seen[$item]:-}" ]] || backup_die "required artifact missing: $item"; done
[[ "$artifact_count" == "$root_count" ]] || backup_die 'root manifest and encrypted manifest artifact counts differ.'
```

【攻撃/事故】rootは`manifest.tsv.age`を1件に数えますが、暗号化されたmanifest本文は自分自身のartifact行を含みません。含めると自身のhashが循環し、検査時は復号済みmanifest自身を上書きするため成立しません。R-M2の階層だけをmock側で補正して実生成snapshotを検査すると、exit 64、`root manifest and encrypted manifest artifact counts differ`を再現しました。

【修正案】root側で`manifest.tsv.age`を明示必須にした上で、`root_count == artifact_count + 1`を検査してください。self entryは暗号化manifestへ追加しないでください。

### R-M4 Storage有効時は一時平文が残り、空bucketは`jq -e`で失敗する

【状態】SR-M1未解消
【該当箇所】`scripts/backup/backup-storage.sh:25-33`、`scripts/backup/run-backup.sh:67-69`

```bash
response_file="$BACKUP_PLAINTEXT_DIR/list-${storage_counter}.json"; storage_counter=$((storage_counter + 1))
curl --config "$SUPABASE_STORAGE_CURL_CONFIG" --fail --silent --show-error --max-time 120 --retry 2 \
  -X POST "${storage_api}/object/list/${bucket}" \
  -H 'Content-Type: application/json' \
  --data "$(jq -cn --arg prefix "$prefix" --argjson offset "$offset" '{prefix:$prefix,limit:1000,offset:$offset,sortBy:{column:"name",order:"asc"}}')" -o "$response_file"
jq -e 'type == "array" and all(.[]; type == "object" and (.name|type == "string") and ((.id == null) or (.id|type == "string")))' "$response_file" >/dev/null || backup_die "Storage API returned invalid JSON for bucket: ${bucket}"
count="$(jq -e 'length' "$response_file")"
parsed_file="$BACKUP_PLAINTEXT_DIR/list-${storage_counter}.tsv"; storage_counter=$((storage_counter + 1))
jq -er '.[] | [if (.id == null) then "directory" else "file" end, (.name | @base64)] | @tsv' "$response_file" > "$parsed_file"
```

```bash
record_artifact 'manifest.tsv' "$BACKUP_MANIFEST_TSV"
find "$BACKUP_PLAINTEXT_DIR" -type f -print -quit | grep -q . && backup_die 'plaintext artifact remained after encryption.'
```

【攻撃/事故】200 `null`はexit 64となり初回問題は部分解消しました。一方、200 `[]`は`jq -e`が結果を1件も出さないためexit 4となることをmock再現しました。jq公式仕様も「有効な結果がなければ4」です。[jq `--exit-status`](https://jqlang.org/manual/v1.6/)

さらに`response_file`と`parsed_file`を削除していないため、オブジェクトが1件以上でもrun-backup line 69が必ず失敗します。重複bucket/object、ページ総数、1000/1001境界もproducerで検査・記録されず、現テストはStorage正常経路を一度も実行していません。

【修正案】list応答はstage内の別scratchへ置き、各ページ処理直後に削除してください。空配列の`.[]`は正常0件として扱い、schema検証の`jq -e`と列挙用jqを分けます。bucket/object論理キーの重複をupload前に拒否し、0/1/999/1000/1001件、再帰prefix、Unicode、空名、`..\\`、tab/newline、途中ページ失敗を自動化してください。

### R-M5 Windows復旧ではmode 0600検査が通らず、DB隔離guardも実hostを固定しない

【状態】SR-M3未解消
【該当箇所】`scripts/backup/restore-db.sh:19-24`

```bash
[[ "$(stat -c '%a' "$RESTORE_DB_SERVICE_FILE")" == 600 ]] || backup_die 'RESTORE_DB_SERVICE_FILE must be mode 0600.'
grep -Fxq "host=${RESTORE_DB_EXPECTED_HOST}" "$RESTORE_DB_SERVICE_FILE" || backup_die 'restore target host is not allowlisted.'
identity="$(PGSERVICEFILE="$RESTORE_DB_SERVICE_FILE" psql --no-psqlrc --tuples-only --no-align --dbname 'service=daida_restore' --command 'select current_database() || E"\t" || current_user')"
[[ "$identity" == "$RESTORE_DB_EXPECTED_DATABASE"$'\t'"$RESTORE_DB_EXPECTED_USER" ]] || backup_die 'restore target database/user is not allowlisted.'
marker="$(PGSERVICEFILE="$RESTORE_DB_SERVICE_FILE" psql --no-psqlrc --tuples-only --no-align --dbname 'service=daida_restore' --command "$RESTORE_DB_MARKER_QUERY")"
[[ "$marker" == "$RESTORE_DB_MARKER_VALUE" ]] || backup_die 'restore target marker verification failed.'
```

【攻撃/事故】指定環境のGit Bash上で`chmod 600 <temp>`後も`stat -c %a`は`644`となり、Windows復旧手順ではpsql前に必ずexit 64です。さらにhost確認はservice fileに期待文字列が「存在するか」だけです。libpqは重複parameterの最後を採用するため、後段に別hostがあってもgrepは通ります。[PostgreSQL service file](https://www.postgresql.org/docs/18/libpq-pgservice.html)、[接続parameterの後勝ち規則](https://www.postgresql.org/docs/current/libpq-connect.html)

identity SQLのescape stringも`E"\t"`ではなく`E'\t'`が正しい構文です。`docs/backup/restore.md:41-47`は必須の`RESTORE_DB_EXPECTED_HOST`と`RESTORE_DB_MARKER_VALUE`を実際に設定していません。既知本番host/refの明示拒否もありません。

【修正案】Windows ACLはPowerShell/`icacls`で所有者以外の読取ACEがないことを検査するラッパーへ分けてください。service fileを構文解析してhost/hostaddr/port/db/userの一意性を確認し、接続後に`inet_server_addr()`等も照合、既知本番ref/hostをdenylistで拒否します。SQL文字列と手順書の必須envも修正し、Windows実機＋実Postgresでguard通過/拒否を試験してください。

### R-M6 Environment文書の「手動だけ承認」はscheduleと両立せず、実設定も未確認

【状態】SR-M7未解消 / 外部運用前提
【該当箇所】`.github/workflows/backup-to-r2.yml:18-22`、`docs/backup/README.md:16-18`

```yaml
jobs:
  backup:
    environment: backup-production
    runs-on: ubuntu-24.04
    timeout-minutes: 55
```

```markdown
> 重要: 本番のSecretsはrepository-levelではなく、保護されたGitHub Environment **`backup-production`**へ登録します。Environmentは既定ブランチのみ許可し、手動実行にはrequired reviewerを設定します。schedule実行は承認待ちにしない運用で、Environmentのbranch制限とSecrets分離を必ず有効にします。
```

【攻撃/事故】GitHubのrequired reviewerは、そのEnvironmentを参照するjobに適用され、event別には外れません。現在はscheduleとmanualが同じjob/Environmentなので、reviewerを有効にすると日次scheduleも承認待ちになります。無効にすると「手動実行だけreviewer」の防御はありません。Environment branch ruleとSecrets移行はリポジトリ外設定なので今回未検証です。[GitHub Environments](https://docs.github.com/en/actions/reference/workflows-and-actions/deployments-and-environments)

【修正案】scheduleとmanualを別job/別Environmentに分け、両方をselected default branchへ限定してください。manual側だけrequired reviewer、schedule側は自動実行可能な保護規則にします。本番有効化前にEnvironment secrets一覧、repository secretsが空であること、deployment branch rule、schedule実行結果を画面/APIで記録してください。

### R-M7 R2 Lock attestationは文字列だけで、削除耐性を検証しない

【状態】SR-M8未解消 / 外部運用前提
【該当箇所】`scripts/backup/run-backup.sh:13-20`

```bash
require_env SUPABASE_DB_SERVICE_FILE
require_env BACKUP_SIGNING_KEY_FILE
require_env R2_RETENTION_LOCK_CONFIRMED
[[ "$R2_RETENTION_LOCK_CONFIRMED" == 'true' ]] || backup_die 'R2_RETENTION_LOCK_CONFIRMED=true is required before uploading.'
validate_age_public_key
validate_r2_component "$R2_BUCKET" R2_BUCKET
validate_r2_component "$R2_PREFIX" R2_PREFIX
[[ "$R2_ENDPOINT" =~ ^https://[A-Za-z0-9.-]+(:[0-9]+)?$ ]] || backup_die 'R2_ENDPOINT must be an HTTPS S3 endpoint without a path.'
```

【攻撃/事故】Variableを`true`にするだけで通り、daily 90日/monthly 400日のLock rule、Lifecycle、管理者分離を読みません。R2 Object Read & Write tokenが漏れ、実Lockが未設定なら全snapshotを削除できます。署名は偽造を防いでも削除を防ぎません。

【修正案】外部前提として残すなら、ユーザーがCloudflare画面/APIでLock/Lifecycleを確認し、日付・rule ID・保持日数を復旧台帳へ記録して明示受容してください。可能ならread-only管理APIによる事前検査を別jobで行い、別事業者/暗号化USBへの月次コピーを初回から実施します。

### R-M8 署名秘密鍵の例示ファイル名が`.gitignore`に含まれない

【状態】新規問題
【該当箇所】`.gitignore:1-4`、`docs/backup/README.md:64`

```gitignore
# age 復号用秘密鍵は、暗号化バックアップそのものと別に絶対に追跡しない。
backup-key.txt
*.agekey
*.age-secret-key
```

【攻撃/事故】手順書は`openssl genpkey ... -out backup-signing-private.pem`を例示しますが、この名前は無視対象外です。リポジトリをカレントにしたまま生成し`git add .`すると署名秘密鍵をcommitでき、以後R2書込者が偽snapshotへ正規署名できます。

【修正案】例示コマンドを必ずリポジトリ外の絶対パスにし、`backup-signing-private.pem`、`pg_service.conf`、`storage-curl.conf`等の具体名もignoreしてください。公開鍵は別名で管理し、秘密鍵だけを対象にすること。secret scanで`BEGIN PRIVATE KEY`を拒否するテストも追加してください。

## 低リスク指摘

### R-L1 `_SUCCESS`前にR2 HEAD/size検証をしていない

【該当箇所】`scripts/backup/lib.sh:83-90`、`scripts/backup/run-backup.sh:82-86`

```bash
aws s3 cp "$encrypted_file" "s3://${R2_BUCKET}/${object}" \
  --endpoint-url "$R2_ENDPOINT" --only-show-errors
done < <(find "$BACKUP_SNAPSHOT_DIR" -type f -print0 | sort -z)
```

【事故】`cp`の成功だけでmarkerを作り、要求されていたremote HEADのContentLength/metadata検証がありません。marker単体の改変は署名済みsnapshot ID照合を回避しませんが、remote一式を実測確認した完了証明にはなっていません。

【修正案】全keyへ`head-object`し、ContentLengthをlocal sizeと照合してからmarkerをPutし、markerもHEADしてください。

### R-L2 子processへのsecret分離は部分的

【該当箇所】`.github/workflows/backup-to-r2.yml:99-107`

```yaml
env:
  AWS_ACCESS_KEY_ID: ${{ secrets.R2_ACCESS_KEY_ID }}
  AWS_SECRET_ACCESS_KEY: ${{ secrets.R2_SECRET_ACCESS_KEY }}
  BACKUP_HEARTBEAT_URL: ${{ secrets.BACKUP_HEARTBEAT_URL }}
  SUPABASE_DB_SERVICE_FILE: ${{ runner.temp }}/pg_service.conf
  SUPABASE_STORAGE_CURL_CONFIG: ${{ runner.temp }}/storage-curl.conf
  BACKUP_SIGNING_KEY_FILE: ${{ runner.temp }}/backup-signing.pem
```

【事故】Supabase CLIではAWS/GitHub等をunsetしていますが、run-backup配下のage/git/tar/openssl等はAWS秘密と全credential file pathを継承します。固定hash済みツールとGitHub-hosted runnerのため直ちに中へは上げませんが、最小secret分離は未達です。

【修正案】取得・署名・uploadを別process/job境界へ分け、各コマンドへ必要なenv/fileだけを渡してください。Storage無効時はService Role key file自体を作らないでください。

### R-L3 STATEとテストが古い合格根拠を残し、end-to-endを検証していない

【該当箇所】`tests/backup/run-tests.sh:122-127`、`ops/backup/STATE.md:52-56,114`

```bash
if source "$ROOT/scripts/backup/lib.sh"; ! validate_safe_logical_path 'storage/a/..\\..\\escaped'; then pass 'SR-H1 Windows backslash traversal is rejected'; else fail 'SR-H1 traversal'; fi
if grep -q 'https://${SUPABASE_PROJECT_REF}.supabase.co' "$ROOT/scripts/backup/backup-storage.sh" && ! grep -q 'SUPABASE_STORAGE_URL' "$ROOT/scripts/backup/backup-storage.sh"; then pass 'SR-H2 host is derived from project ref'; else fail 'SR-H2 host allowlist'; fi
if grep -q 'pkeyutl -verify' "$ROOT/scripts/backup/inspect-backup.sh" && grep -q '_SUCCESS' "$ROOT/scripts/backup/inspect-backup.sh"; then pass 'SR-H3/L1 unsigned or incomplete snapshots are rejected'; else fail 'SR-H3/L1 signature'; fi
if grep -q 'type == "array"' "$ROOT/scripts/backup/backup-storage.sh" && ! grep -q 'SUPABASE_STORAGE_SERVICE_ROLE_KEY' "$ROOT/scripts/backup/backup-storage.sh"; then pass 'SR-M1/M4 Storage schema and credential-file controls'; else fail 'SR-M1/M4'; fi
```

【事故】現テストは19/0ですが、署名・Storage・inspectの主要部分はgrepだけです。STATE前半は「inspection valid/tamper testを含む17件」と古いログを残し、末尾だけ19件へ更新しています。実際には生成→upload→inspectがなく、R-M2/R-M3/R-M4を検出できませんでした。

【修正案】STATEの古い17件一覧を削除せず履歴化するなら「是正前」と明示し、現在の実行ログを正本にしてください。偽crypto mockだけでなく実OpenSSL/ageを使うend-to-end、R2 tree mock、Storage 0/1000/1001件を追加します。

## 独立実行結果

```text
Bash構文: PASS
tests/backup/run-tests.sh: passed=19 failed=0（約30秒。静的grep中心）
git diff --check: exit 0（既存CRLF警告のみ）
shellcheck: 未導入 / actionlint: 未導入

Windows ..\\ probe: REJECTED
HTTP 200 null Storage list: exit 64（拒否）
HTTP 200 [] Storage list: exit 4（正常な空bucketを拒否）
署名: valid ACCEPTED / root改変 REJECTED / 別公開鍵 REJECTED
改行を含むEd25519 PEM Secretのprintf復元: mode 600 / key parse PASS
空manifest（正規署名root、必須artifact行0）: exit 64 required artifact missing
実生成upload treeをそのままinspect: exit 64 required manifest/signature/_SUCCESS missing
upload階層だけ補正した実生成snapshot: exit 64 root/artifact counts differ
Git Bash chmod 600後のstat: 644（Windows restore guardを通過不能）
Supabase CLI誤URL: HTTP 404 / 正しいasset: HTTP 200
```

## 未検証境界

- 本物のSupabase DB/Storage、R2、GitHub Actions、GitHub Environmentへは接続していません。
- R2 Bucket Lock/Lifecycle、Object token実権限、別媒体月次複製、30時間heartbeat alertは未確認です。
- GitHub EnvironmentのSecrets所在、selected default branch rule、required reviewerの実設定は未確認です。
- Supabase CLI公式checksum/asset名は一次情報で照合しましたが、workflow上での実展開・実DB dumpは未実行です。
- `shellcheck`と`actionlint`はローカル未導入のため未検証です。package/lockfileはなく、npm依存監査の対象はありません。
- 実Postgres/Supabase隔離復元、Windows ACL、実ageによる完全snapshot復号、Storage 1000/1001件・同時更新は未検証です。

## 最終判定

**差し戻し。高0件は達成しましたが、中8件が残っています。**

最低でもR-M1〜R-M5とR-M8をコード・テストで解消してください。R-M6/R-M7は外部設定を実確認し、解消できない部分をユーザーが明示受容する必要があります。その後、別担当が「実生成→R2同型tree→署名検証→復号→隔離復元」を再実行するまで本番有効化不可です。
