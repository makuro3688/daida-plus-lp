# DAIDA+ 暗号化オフサイトバックアップ

この仕組みは、SupabaseまたはGitHubの誤削除・アカウント喪失・障害時に、専用Google Driveへ保存した**age暗号化済みスナップショット**から復旧するためのものです。本番設定を自動変更しません。

## 保存するもの / 保存しないもの

| 対象 | 保存方法 | 注意 |
|---|---|---|
| Supabase DB | PostgreSQL 17公式クライアントで`roles.sql` / `schema.sql` / `data.sql`を作成 | Storage実ファイルはDBバックアップに含まれません |
| Supabase Storage | 有効化されたバケットの全オブジェクトを日時別に取得 | `sync --delete`は使いません |
| Git リポジトリ | GitHubから`clone --mirror`し全参照をアーカイブ | 未コミットのローカル作業は含まれません |
| Issue/PR/コメント/Wiki/Releases/LFS/Actions Secrets/環境設定 | **含まれない** | 下記の復旧台帳で別管理します |

Supabase公式も、論理DBバックアップは`roles`・`schema`・`data`を分け、Storage実ファイルは別途扱うと案内しています。公式資料: [Backup and Restore using the CLI](https://supabase.com/docs/guides/platform/migrating-within-supabase/backup-restore)、[Database Backups](https://supabase.com/docs/guides/platform/backups)。

## 事前設定（本番画面でユーザーが行うこと）

> 重要: 本番のSecretsはrepository-levelではなく、保護されたGitHub Environmentへ登録します。`backup-scheduled`と`backup-manual`の両方を既定ブランチのみに限定し、manual側だけrequired reviewerを設定します。schedule側は日次自動実行を妨げない保護規則にします。2026-09-04に両Environmentの作成・`main`限定、現在の構成で必要なSecretsとVariablesの登録、manual側のrequired reviewer設定まで完了しました。workflowは`main`へ反映済みで、毎日JST 04:00の自動実行が有効です。同日に初回手動バックアップ（Actions run #7）が成功し、Google Drive上の完了マーカーと暗号化済みDB・Gitミラーを確認しました。

### 1. age 鍵

1. `age-keygen`で鍵を作る。GitHubへ登録するのは`age1...`で始まる**公開鍵だけ**です。
2. `AGE-SECRET-KEY-1...`を含む秘密鍵ファイルは、パスワードマネージャーと暗号化USBなど独立した2か所に保管します。
3. 秘密鍵をリポジトリ、GitHub Secrets、Issue、Actionsログ、AIチャットへ置かないでください。紛失時はバックアップを復号できません。

Windowsでは、秘密鍵をリポジトリやOneDrive同期デスクトップへコピーしません。例として`D:\DAIDA-backup-keys\backup-key.txt`のようなBitLocker暗号化済みローカル領域または暗号化USBで保管し、復旧時だけ指定します。Windowsの実行制御で`age.exe`が拒否される場合はポリシーを解除せず、WSL2上の公式`age`から保管先を`/mnt/d/...`として直接参照します。

BitLocker未設定のUSBを使う場合は、平文鍵を保存せず、WSL上で`bash scripts/backup/create-age-key-usb.sh /mnt/d`を実行してパスフレーズ暗号化済みの`backup-key.txt.age`だけを保存します。パスフレーズはUSBとは別のパスワードマネージャーまたは紙へ保管します。

### 2. Supabaseバックアップ専用ユーザー

本番の`postgres`管理者パスワードは使わず、`daida_backup_reader`を使用します。このユーザーは`pg_read_all_data`と`BYPASSRLS`でバックアップ対象を読み取れますが、テーブルの`INSERT`・`UPDATE`・`DELETE`・`TRUNCATE`、スキーマ作成、DB作成、ロール作成、複製の権限を持ちません。資格情報が漏れた場合でも削除・改変はできませんが、全データを読み取られる可能性はあるためSecretとして扱います。

2026-09-04に本番`main`で、専用ユーザーの接続、書込み権限ゼロ、`roles.sql`・`schema.sql`・`data.sql`の論理ダンプ作成を実測済みです。パスワードはリポジトリ、文書、AIチャットへ保存しません。

### 3. バックアップ専用Google Drive

個人メールとは別のGoogleアカウントを用意します。GitHub Actionsからはrcloneの`drive.file`スコープだけを使い、この接続で作成したファイルだけを管理します。`DAIDA-BACKUPS`はrclone接続から作成してください。Google Drive画面で手作業で作った同名フォルダは`drive.file`接続から見えず、重複の原因になります。

| プレフィックス | 自動整理 | 用途 |
|---|---:|---|
| `DAIDA-BACKUPS/snapshots/daily/` | 35日経過後にゴミ箱へ | 毎日の復旧点 |
| `DAIDA-BACKUPS/snapshots/monthly/` | 400日経過後にゴミ箱へ | 毎月1日の長期復旧点 |

Google DriveにはR2 Bucket Lock相当の削除ロックがありません。自動整理は即時消去せずGoogle Driveのゴミ箱を使い、ゴミ箱をワークフローから空にしません。OAuthトークンやGoogleアカウント自体の侵害には残存リスクがあるため、月1回、暗号化済みスナップショットを別の暗号化USBへ複製します。

### 4. GitHub Variables / Secrets

リポジトリの **Settings → Secrets and variables → Actions** で以下を登録します。値はログへ出力しません。

| 種別 | 名前 | 内容 | 最小権限 / 備考 |
|---|---|---|---|
| Variable | `AGE_PUBLIC_KEY` | `age1...`公開鍵 | 秘密ではない。秘密鍵は登録禁止 |
| Variable | `SUPABASE_PROJECT_REF` | 20文字のProject Ref | URLではなくRefのみ。通信先はコードが`https://<ref>.supabase.co`へ固定導出 |
| Variable | `GDRIVE_BACKUP_ROOT` | `DAIDA-BACKUPS` | 専用アカウントの専用フォルダ |
| Variable | `GDRIVE_RCLONE_CLIENT_ID` | 専用Desktop OAuth client ID | rclone共用client IDは使わない |
| Variable | `GDRIVE_DAILY_RETENTION_DAYS` | `35` | 経過後にゴミ箱へ移す |
| Variable | `GDRIVE_MONTHLY_RETENTION_DAYS` | `400` | 経過後にゴミ箱へ移す |
| Variable | `GDRIVE_RESIDUAL_RISK_ACCEPTED` | `true` | 削除ロックがない残存リスクと月次USB複製を確認してから設定 |
| Variable | `BACKUP_STORAGE_ENABLED` | `true`または`false` | 未使用時は必ず`false`。未設定も安全にスキップ |
| Variable | `SUPABASE_STORAGE_BUCKETS` | `bucket-a,bucket-b` | `true`時は必須。全バケットを意図的に列挙 |
| Secret | `SUPABASE_BACKUP_DB_URL` | `daida_backup_reader`専用のSession pooler接続URL | 5432を使用。`postgres`管理者URLとTransaction pooler 6543は禁止 |
| Secret | `SUPABASE_SERVICE_ROLE_KEY` | Storage読取用Service Role key | Storage有効時のみ。強力な秘密 |
| Secret | `GDRIVE_RCLONE_TOKEN` | rcloneが発行したGoogle Drive OAuth token JSON | `drive.file`スコープ。画面・ログ・リポジトリへ表示しない |
| Secret | `GDRIVE_RCLONE_CLIENT_SECRET` | 専用Desktop OAuth client secret | tokenとは別のSecretとして登録 |
| Secret（任意） | `BACKUP_HEARTBEAT_URL` | 外部監視の成功通知URL | 成功後にだけPOST。失敗時はWorkflow失敗 |
| Secret | `BACKUP_SIGNING_PRIVATE_KEY` | Ed25519署名秘密鍵のPEM | **`backup-scheduled` と `backup-manual` の両Environment Secret**へ登録。age鍵・Google資格情報と別に保管 |

署名鍵は隔離端末で生成します（例: `openssl genpkey -algorithm Ed25519 -out backup-signing-private.pem`、`openssl pkey -in backup-signing-private.pem -pubout -out backup-signing-public.pem`）。秘密PEMはEnvironment Secretへ、公開PEMはリポジトリ外のパスワードマネージャー・暗号化USBへ二重保管します。復元時、`root-manifest.tsv`の署名をこの信頼済み公開鍵で検証します。Google Driveにある公開鍵や署名だけを信頼してはいけません。

接続URLはSupabaseの**Session pooler（5432）**を既定とし、IPv6またはIPv4 add-on利用時はDirect（5432）を使います。公式の接続・ダンプ手順を参照してください。[Supabase CLIバックアップ](https://supabase.com/docs/guides/platform/migrating-within-supabase/backup-restore)

`age`はワークフロー内でv1.3.2へ固定し、公式リリースに掲載されたSHA-256で検証します。更新時はバージョン・URL・SHA-256を同じ変更としてレビューしてください。

DBダンプには、ダイジェスト固定したPostgreSQL 17公式コンテナを使います。Supabase CLIと同等の対象除外フィルタを維持しつつ、管理者ロールへの切替は行いません。DB URL/Storage key/署名鍵は0600の一時ファイルへだけ書き、各工程終了後に削除します。DB接続URLはDockerの一時環境ファイルからコンテナへ渡し、ホスト側のコマンド引数やログへ出しません。DB資格情報は読み取り専用ユーザーへ限定します。

Google Driveは削除ロックを提供しません。本番有効化前に、専用アカウント、`drive.file`スコープ、daily 35日・monthly 400日、確認日、確認者、月次USB複製先を`recovery-inventory.md`へ記録してください。`GDRIVE_RESIDUAL_RISK_ACCEPTED=true`は、この残存リスクを理解したことの記録であり、防御機能そのものではありません。

## 動作

ワークフローは毎日JST 04:00（UTC 19:00）と手動実行で起動します。DB、必要なStorage、Gitミラーを一時領域で取得し、各ファイルを公開鍵で暗号化してから、Google Driveの日時別フォルダへ保存します。月初は同じスナップショットを`daily`と`monthly`の両方へ保存します。暗号化されたマニフェストには時刻、サイズ、平文・暗号文のSHA-256が含まれます。

設定不足、空ファイル、コマンド失敗、age失敗、Google Drive失敗、ハートビート失敗はすべて失敗として終了します。GitHubのcron停止やリポジトリ削除を検知するため、外部ハートビート監視を設定し「30時間以内に成功通知なし」で通知してください。

GitHubの定期実行は、公開リポジトリで活動がない場合に自動停止することがあります。Actions画面とハートビートを月次点検してください。[GitHub scheduled workflows](https://docs.github.com/en/actions/reference/workflows-and-actions/events-that-trigger-workflows#schedule)

## 追加で管理する復旧台帳

`docs/backup/recovery-inventory.md`を、設定変更のたびに更新します。特に次はGitミラーやDBだけでは戻りません。

- Supabase Auth設定、リダイレクトURL、メールテンプレート、API keys、Realtime publication、Edge Functions、DB extensions
- Supabase Storageのバケット設定・ポリシー
- Renderのサービス設定・環境変数・デプロイ設定
- Cloudflare DNS、Email Routing設定
- Google Drive専用アカウント、OAuth接続、保持設定、USB複製記録
- Resend設定
- GitHub Issues、PR、コメント、Wiki、Releases、LFS、ブランチ保護、Actions Variables/Secrets

Actions Secretsの値はGitHubから再取得できません。作成時に、パスワードマネージャーへ値と用途・更新日を保管します。

## ローカル検査と復旧

復旧作業は本番ではなく、ネットワーク分離または別アカウントのテスト環境で最初に実施します。詳細は[復旧手順](restore.md)を参照してください。

## ローカルテスト

Git Bashが入ったWindowsでは、次で本番資格情報なしにテストできます。

```powershell
& 'C:\Program Files\Git\bin\bash.exe' tests/backup/run-tests.sh
```

テストは外部接続をモックし、設定不足、空ダンプ、ダンプ失敗、暗号化失敗、Google Driveアップロード失敗、Storage設定不足、正常な日次スナップショットを確認します。
