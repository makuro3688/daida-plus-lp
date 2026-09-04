# DAIDA+ 災害復旧バックアップ 独立QA報告

確認日: 2026-09-01
対象: 現行の `.github/workflows/backup-to-r2.yml`、`scripts/backup/`、`docs/backup/`、`tests/backup/`

## 総合判定

- オフライン実装: **条件付き合格**
- 受け入れ完了: **未完了**
- 本番Workflow有効化: **不可**
- 理由: AC-5の設定文書不整合は是正済み。コード・文書としてAC-1〜7、9は合格したが、AC-8の実`age`復号・隔離Supabase復元、AC-10の既存dirty変更非干渉は独立証明できていない。
- 現時点で許可できる範囲: workflow・スクリプト・文書をリポジトリに置いてレビューを続けること。本番Secrets登録、`R2_RETENTION_LOCK_CONFIRMED=true`設定、手動実行、schedule実行は行わない。

## 独立実行結果

| 確認 | 結果 |
|---|---|
| Bash構文 | PASS: `scripts/backup/*.sh`、`tests/backup/*.sh` |
| PowerShell構文 | PASS: `verify-windows-acl.ps1` |
| 統合テスト | PASS: `timeout 120 bash tests/backup/run-tests.sh`、exit 0、`passed=23 failed=0` |
| Storage境界 | PASS: 0 / 1 / 1000 / 1001件、offset=1000、2ページ目HTTP失敗拒否 |
| R2同型tree検査 | PASS: 実OpenSSL署名検証、暗号文改変・root manifest改変・別公開鍵・`_SUCCESS`欠落を拒否 |
| 実age | UNVERIFIED: Windows Device Guardで`age.exe`が起動できず、E2Eはmock-ageへfallback |
| 差分空白 | PASS: `git diff --check` exit 0。CRLF変換警告のみ |

## AC別判定

| AC | 判定 | 根拠・残件 |
|---|---|---|
| AC-1 | **PASS** | JST 04:00相当の`0 19 * * *`、手動実行、`cancel-in-progress: false`、55分timeout、`contents: read`を確認。 |
| AC-2 | **PASS** | DBをroles/schema/dataへ分割し、公開鍵のみで各artifactを暗号化する。日時＋run IDの一意prefixを使用し、秘密鍵を自動処理へ要求しない。実Linux Actions実行は外部確認待ち。 |
| AC-3 | **PASS** | Storageは個別取得・日時別暗号化snapshotで、削除伝播syncを使わない。無効時は資格情報ファイルを作らずskip。ページ境界と途中失敗を自動試験済み。実Supabase/R2 APIは未接続。 |
| AC-4 | **PASS** | `clone --mirror`、`git fsck`、暗号化archiveを確認。Issue/PR/Wiki/Releases/LFS/Secrets等が対象外であることも文書化済み。 |
| AC-5 | **PASS** | 秘密の直書きは見つからず、必要なVariables / Secretsと最小権限方針を文書化。未使用の`SUPABASE_URL`は削除され、`BACKUP_SIGNING_PRIVATE_KEY`の登録先もworkflowと同じ`backup-scheduled` / `backup-manual`両Environmentへ統一された。外部画面での登録自体は未実施。 |
| AC-6 | **PASS** | `set -Eeuo pipefail`、非空確認、失敗時停止、暗号化manifest、署名済みroot manifest、R2 HEADサイズ確認、完了後のみ`_SUCCESS`とheartbeatを確認。異常系テスト合格。 |
| AC-7 | **PASS** | daily 90日、monthly 400日、Bucket Lock/Lifecycle、管理権限分離、月次別媒体複製を文書化。Cloudflare実設定と台帳記入は外部未実施。 |
| AC-8 | **UNVERIFIED** | Windows用の検査・ACL guard・隔離DB復元手順は存在するが、この端末では実`age`がDevice Guardで拒否される。実暗号文の復号、実Postgres guard、本番先拒否、隔離Supabase復元は未実施。 |
| AC-9 | **PASS** | 本番資格情報なしで正常系・設定不足・空出力・コマンド/暗号化/upload失敗・Storage境界・改変拒否を検証し、23件合格。ただしage、Supabase、R2、DB dump、Gitの一部はmock。 |
| AC-10 | **UNVERIFIED** | バックアップ追加パスはWebサイト本体と分離され、`index.html`や画像の新規差分は見当たらない。一方、作業ツリーには`flyer/`、`LESSONS.md`、多数の既存untrackedファイルがあり、QA開始前baselineがないため、それらへ今回の作業が非干渉だったことをGitだけでは独立証明できない。既存dirtyとして分離し、commit対象をbackup関連pathに限定する必要がある。 |

## 本番有効化前の必須是正・外部確認

1. GitHubで両Environmentを既定branch限定、manualだけreviewer必須にし、対象Secretsをrepository-levelへ置かない。
2. R2のdaily 90日 / monthly 400日Lock・Lifecycle、管理者分離、別媒体複製先を設定し、Rule ID・確認日・確認者を復旧台帳へ記録する。
3. 承認済みの別Windows端末または許可されたLinux/WSL環境で、実`age`による復号・inspectを通す。Device Guardを回避・無効化しない。
4. Linux Actionsで実バックアップを1回作成し、read-only R2資格情報で取得後、隔離SupabaseへDB/Storage/Gitを復元する。実Windows ACL guardと本番Project Ref拒否も確認する。
5. commit前にbackup関連pathだけを明示選択し、既存のflyer/report等のdirty変更を混入させない。

上記1〜4を実環境で成功させるまでは、災害時に復元できる状態を受け入れ完了とは判定しない。
