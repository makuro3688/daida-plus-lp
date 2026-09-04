# 復旧台帳（テンプレート）

> 値そのもの（秘密鍵、トークン、パスワード、接続URL）はこのファイルに書かない。保管場所・担当者・最終確認日だけを記録する。

| 区分 | 設定・資産 | 保管場所 / 復旧方法 | 担当 | 最終確認日 |
|---|---|---|---|---|
| age | 秘密鍵の二重保管 | パスフレーズを別保管した暗号化USB | makuro3688 | 2026-09-04（暗号化秘密鍵・署名公開鍵を確認） |
| Google Drive | 専用アカウント、`DAIDA-BACKUPS`、復旧用read-only接続 | Google Drive・パスワードマネージャー | 2026-09-02 | 専用アカウントとフォルダ作成済み |
| Google Drive保持 | daily 35日、monthly 400日、ゴミ箱利用、月次USB複製先 | GitHub Variables・月次確認記録 | makuro3688 | 2026-09-04（残存リスク受容を登録） |
| Supabase | Project Ref、DB extensions、Realtime publication | Supabase管理画面 | 2026-09-04 | 本番`main`を確認 |
| Supabase DBバックアップ | `daida_backup_reader`、読取専用接続URL | Supabase / GitHub Environment Secret | 2026-09-04 | 接続・書込み権限ゼロ・3分割dump成功 |
| Supabase Auth | Site URL、Redirect URL、メールテンプレート、プロバイダ設定 | Supabase管理画面 | 未記入 | 未記入 |
| Supabase Storage | バケット、MIME制限、上限、ポリシー | Supabase管理画面 / SQL | 未記入 | 未記入 |
| Supabase Functions | Edge Functions、環境変数の保管場所 | Git / パスワードマネージャー | 未記入 | 未記入 |
| GitHub | バックアップ用Environment、Actions Variables/Secrets | GitHub管理画面 / 独立保管 | makuro3688 | 2026-09-04（manual: 2保護規則・4 Secrets・8 Variables、scheduled: 1保護規則・4 Secrets・8 Variables） |
| Render | サービス、ビルド/開始コマンド、環境変数 | Render管理画面 | 未記入 | 未記入 |
| Cloudflare | DNS、Email Routing | Cloudflare管理画面 | 未記入 | 未記入 |
| Resend | ドメイン、DNS、メールテンプレート | Resend管理画面 | 未記入 | 未記入 |

設定変更時と復旧訓練後に更新する。
