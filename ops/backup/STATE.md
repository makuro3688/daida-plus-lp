# バックアップ実装 現在の状態

更新: 2026-09-05

## 採用構成

- 実行: GitHub Actions（毎日JST 04:00、手動実行にも対応）
- 保存先: 専用Google Driveアカウントの`DAIDA-BACKUPS`
- 暗号化: age公開鍵暗号化。復号秘密鍵は暗号化USBに保管
- 改ざん検知: Ed25519署名。公開検証鍵はGoogle Driveと別に保管
- DB: ダイジェスト固定したPostgreSQL 17公式クライアントによる`roles.sql`・`schema.sql`・`data.sql`
- Git: `clone --mirror`の暗号化アーカイブ
- Storage: 本番にバケットがないため現在は無効
- 保持: daily 35日、monthly 400日。削除はDriveのゴミ箱へ移動

## 外部設定の完了事項

- WSL2 / Ubuntuを導入済み。
- WSLへage v1.3.2、rclone v1.75.0、PostgreSQL client 18.6を導入済み。
- age秘密鍵をパスフレーズ暗号化してUSBへ保存済み。平文秘密鍵はUSBへ残していない。
- age公開鍵の形式を確認し、Ed25519署名公開鍵を復旧用USBへ追加・コピー検証済み。
- Google Cloudで専用Desktop OAuth clientを作成し、`drive.file`だけを許可済み。
- rclone認証、専用Drive内の`DAIDA-BACKUPS`作成・表示を確認済み。
- Ed25519署名鍵をWSLで作成・検証済み。秘密鍵は両GitHub Environmentへ登録し、公開鍵は復旧用USBへ保管済み。
- GitHubに`backup-scheduled`と`backup-manual` Environmentを作成し、両方を`main`ブランチ限定に設定済み。
- `backup-manual`は`makuro3688`をrequired reviewerに設定し、本人承認可能。`backup-scheduled`にはreviewerを設定していない。
- 両Environmentへ現在の構成で必要な4 Secretsと8 Variablesを登録済み。Storageバケットがないため`BACKUP_STORAGE_ENABLED=false`。
- 登録に使用したGit除外済み一時資格情報は、登録完了後にメモリとディスクから削除済み。
- 本番Supabaseは`makuro3688's Project` / `main` / Project Ref `xhkamtfwmzgueltekilo`と確認済み。
- 本番Supabase Storageにバケットがないことを確認済み。
- Renderサービス`shift-help-notify-app`はDBパスワードを環境変数に持たず、Supabase API資格情報を使用していることを確認済み。
- GitHub Actionsの初回手動バックアップrun #7（`33844247753`）が2026-09-04に成功。Google Driveで`_SUCCESS`、`manifest.tsv.age`、署名、暗号化済みDB 3ファイル、暗号化済みGitミラー（21.1 MB）を確認済み。

## 専用DBユーザーの実測

2026-09-04、本番Supabaseへ`daida_backup_reader`を作成した。

- `LOGIN=true`
- `SUPERUSER=false`
- `CREATEDB=false`
- `CREATEROLE=false`
- `REPLICATION=false`
- `BYPASSRLS=true`
- `pg_read_all_data`を継承
- 同時接続上限1
- statement timeout 30分
- テーブル書込み権限0件、スキーマ作成権限0件、DB作成権限なし、`pg_write_all_data`非所属
- Session pooler 5432で接続成功
- 実PostgreSQLに対して`roles.sql`・`schema.sql`・`data.sql`相当の取得成功
- 試験用平文ダンプとパスワード一時ファイルは終了時に削除

## コードの現在地

- `.github/workflows/backup-to-google-drive.yml`: Google Drive版workflow。
- `scripts/backup/backup-db.sh`: `SUPABASE_BACKUP_DB_URL`を0600一時ファイルから読み、ダイジェスト固定したPostgreSQL 17公式クライアントで、管理者ロールへ切り替えず3分割dumpを作成。
- `scripts/backup/test-db-connection.sh`: 実接続、書込み権限ゼロ、schema/data/roles dump可否を安全な一時領域で検証。
- `scripts/backup/setup-google-drive-rclone.sh`: `drive.file`限定rclone設定支援。
- `docs/backup/`: Google Drive運用、専用DBユーザー、復旧手順、復旧台帳。

既存Web、画像、料金、リンクおよび既存ユーザー変更は変更していない。

## 最新テスト

2026-09-04、Bash構文検査と`tests/backup/run-tests.sh`を実行し、**passed=24 failed=0**。正常系、設定不足、外部コマンド失敗、空dump、暗号化・アップロード失敗、Storage 0/1/1000/1001件、途中HTTP失敗、実age/OpenSSLによる暗号化・署名・復号、4種類の改ざん拒否に合格した。リポジトリ対象の秘密情報スキャンも合格。

## 残作業

1.日次自動実行は2026-09-05 JST 06:18のrun #8（`33920472388`、`backup-scheduled`、main、所要2分22秒）で初めて成功を確認済み。GitHubのcronは混雑時に遅延するため、起動がJST 04:00ちょうどでなくても異常ではない。以降はActionsとハートビートを月次で点検する。
2. 月1回、最新スナップショットをUSBへ複製し、復号・署名検査を行う。
3. 3か月ごとに隔離した検証環境へDBとGitを復元する。
4. 必要に応じて、30時間成功通知がない場合に知らせる外部ハートビート監視を設定する。

Google Driveには変更不能ロックがない。OAuthまたは専用Googleアカウント自体が侵害されるとバックアップを削除され得るため、月1回、暗号化済みスナップショットを別USBへ複製する。
