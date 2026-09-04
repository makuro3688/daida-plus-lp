# バックアップ 最終リリース前セキュリティ判定

監査日: 2026-09-01
方式: 実装変更なし。現行workflow／`scripts/backup`／`tests/backup`を読み、ローカルで独立実行した。

## 結論

- 高: **0件**
- 中: **1件**
- 低: **0件**
- 外部ブロッカー: **3件**
- 本番Workflow設定開始: **不可**（Secrets登録、`R2_RETENTION_LOCK_CONFIRMED=true`設定、実行開始はいずれも不可）
- 復元可能性: **暗号文・署名・マニフェスト検査の一部は合格。実ageで暗号化された本番スナップショットをWindowsで復号し、隔離Supabaseへ復元できることは未証明。**

## 独立実行結果

| 確認 | 結果 |
|---|---|
| Bash構文 | `scripts/backup/*.sh` と `tests/backup/*.sh` は合格 |
| PowerShell構文 | `scripts/backup/verify-windows-acl.ps1` は合格 |
| 統合テスト | `timeout 120 bash tests/backup/run-tests.sh` は exit 0、`passed=23 failed=0` |
| 差分空白 | `git diff --check` は exit 0（既存CRLF警告のみ） |

## 前回残存事項の再判定

| 前回項目 | 判定 | 現コード・テスト根拠 |
|---|---|---|
| Windows DB guard | **実装は解消、実機確認は外部ブロッカー** | `restore-db.sh` は target/prodの20文字Refの不一致を必須にし、接続hostを`db.<target-ref>.supabase.co`へ固定する。`daida_restore`節の重複、`hostaddr`、host/db/user/port/sslmode不一致を拒否し、Windowsでは`verify-windows-acl.ps1`失敗時に`psql`前で停止する。PowerShellは構文のみ確認済みで、実ACL・実Postgresによる隔離先通過／本番先拒否は未実施。 |
| Storage E2E不足 | **コード上は解消** | `storage-pagination.sh`は現行`backup-storage.sh`をコピーして実行し、0/1/1000/1001件、2ページ目offset=1000、download回数、list(curl)回数、暗号化inventory行数、2ページ目HTTP失敗時の非0終了とinventory未生成を確認した。0/1件は未patchのコピー、1000/1001件だけはテスト専用patchでbase64 decode、URL encode、SHA-256、inventory暗号化を軽量化する。従ってページング制御・offset・curl・inventory・失敗終了は実検証済みだが、大量件数での実エンコード／実hash／実age暗号化、Supabase API/R2 APIは検証していない。 |
| Storage無効時のSecret file | **解消** | workflowは`BACKUP_STORAGE_ENABLED == 'true'`のstepだけにService Role Secretを渡し、`storage-curl.conf`を作る。無効時は作らない。 |

## filesystem R2 E2Eの有効範囲

`e2e-real-crypto.sh`はfilesystem上のR2同型treeをaws mockで作るが、`openssl`は実コマンドでEd25519鍵生成・署名検証を行う。`inspect-backup.sh`による必須artifactの検査も実行し、暗号文1 byte追加、root manifest改変、別公開鍵、`_SUCCESS`欠落の4件を全て拒否した。DB dump、Git、R2 APIはmockであり、外部サービスへのアップロード／ダウンロードを成功扱いに偽装したテストではないが、外部サービスの接続保証にもならない。

## 中: Windowsで実age復号を確認できない

`/c/Users/user/age/age.exe --version`はDevice Guardの`Permission denied`、exit **126**だった。E2Eはこれを回避せず、明示的にmock-ageへfallbackして実OpenSSLだけを検証した。そのためage暗号化・復号は未検証である。

- **Linux Actionsのバックアップ作成**: Windows Device Guardは直接の阻害要因ではない。workflowは`ubuntu-24.04`で公式age tarballをSHA-256照合して導入し、実`age`を必須にしている。ただしGitHub Actionsでの初回実行は未実施で、成功根拠にはできない。
- **Windows復旧**: 実ageを起動できない現在の端末では、本番暗号文の復号可否を確認できない。復旧可能性に直結するため中リスクとする。Device Guardを回避・無効化してはならず、承認済みの別復旧端末または組織ポリシーで許可されたage実行環境で、実ageの復号・inspect・隔離復元を成功させる必要がある。

## 外部ブロッカー（コード外）

1. GitHubで`backup-scheduled`と`backup-manual`を既定branch限定にし、manualだけreviewer必須とする。対象Secretsはrepository-levelに残さない。
2. Cloudflare R2でdaily 90日／monthly 400日のBucket Lock・Lifecycle、管理者分離、別媒体複製先を設定し、Rule ID・確認日・確認者を`docs/backup/recovery-inventory.md`へ記録する。
3. Variables/Secrets登録後、Linux Actionsで実バックアップを1回作成し、read-only R2資格情報で取得して、実ageを使う承認済み復旧環境から署名検証・復号・隔離Supabase DB/Storage/Git復元を実施する。これには上記Windows DB guardの実ACL／本番拒否試験も含める。

上記を満たすまでは、workflowファイルを置くだけの状態に留め、本番Secrets、Lock確認値、手動／schedule実行を有効にしない。
