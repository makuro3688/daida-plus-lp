# DAIDA+ 災害復旧バックアップ 最終セキュリティ判定

監査日: 2026-08-31
方式: 実装変更なし。指定ファイルの読み取り、Git BashによるBash構文検査、`tests/backup/run-tests.sh`の独立実行。外部サービス・本番資格情報には接続していない。

## 結論

- 高: **0件**
- 中: **2件**
- 低: **1件**
- 外部前提: **2件**
- 本番有効化: **不可**

静的に確認できる前回の主要な実装不備（CLI asset/SHA、R2相対階層、root count、Storage空配列・scratch削除、event別Environment、ignore、artifact HEAD）は解消されている。一方で、独立テストは15秒の上限内に完走せず、4件目の失敗系までしか確認できなかった。さらにWindows復元ガード、Storage大容量列挙、実age/OpenSSLによる復号検査は現コード・テストだけでは裏付けられないため、有効化を承認できない。

## 実行結果

| 確認 | 結果 | 根拠 |
|---|---|---|
| Bash構文 | 合格 | Git Bashで`for f in scripts/backup/*.sh tests/backup/run-tests.sh; do bash -n "$f"; done`を実行し構文エラーなし。 |
| 独立テスト | **未完了** | `timeout 15s bash tests/backup/run-tests.sh`はexit **124**。`missing R2 setting`、`command failure`、`empty DB dump`、`encryption failure`の4件はPASS表示後に終了した。`passed=21 failed=0`は再現できていない。 |

## 前回指摘の再判定

| ID | 判定 | 現コード根拠 |
|---|---|---|
| R-M1 | 解消 | workflow 68–72行は`supabase_linux_amd64.tar.gz`、固定SHA、`supabase --version`照合を使用。 |
| R-M2 | 解消 | `lib.sh` 86–91行は`BACKUP_SNAPSHOT_DIR`から相対化し、snapshot直下へuploadしてHEAD sizeを照合。 |
| R-M3 | 解消 | `inspect-backup.sh` 59行はroot件数を`artifact_count + 1`、かつ`manifest.tsv.age`必須として検査。 |
| R-M4 | 解消（境界未検証） | `backup-storage.sh` 31–34行は空配列を真とするschema検査・`length`を分離し、54行で各page scratchを削除。0/1000/1001件の動的E2Eは未実施。 |
| R-M5 | 未解消 | `restore-db.sh` 19–20行はPOSIX `stat -c '%a' == 600`と単純な`grep host=`だけ。Windows ACL検査、service fileの一意構文解析、既知本番host拒否はない。 |
| R-M6 | 外部前提 | workflow 20行はevent別に`backup-manual`/`backup-scheduled`を選ぶ。両Environmentの既定branch制限、manual reviewer、Secrets移行の実設定はコード外で未検証。 |
| R-M7 | 外部前提 | `run-backup.sh` 15–16行は`R2_RETENTION_LOCK_CONFIRMED=true`を要求するのみ。R2 Lock/Lifecycle/管理者分離はCloudflare側の実設定確認が必要。 |
| R-M8 | 解消 | `.gitignore`は`backup-signing-private.pem`、`pg_service.conf`、`storage-curl.conf`を除外。workflowにも`BEGIN PRIVATE KEY`等の直書きはない。 |
| R-L1 | 解消 | `lib.sh` 88–91行で全artifact、`run-backup.sh` 87–89行で`_SUCCESS`のR2 ContentLengthを照合。 |
| R-L2 | 未解消（低） | workflow 87–97行は`BACKUP_STORAGE_ENABLED=false`でもService Role Secretをstepへ渡し、`storage-curl.conf`を常に作成する。Storage無効時にcredential fileを作らない分岐はない。 |
| R-L3 | 未解消（中） | `tests/backup/run-tests.sh` 94–143行はmock中心で、実age/OpenSSL、Storage 1000/1001件、upload→download→inspectのE2Eを実施しない。今回もテスト全件完走を再現できなかった。 |

## 残存リスク

### 中: Windows DB復元ガードが本番拒否を保証しない

`scripts/backup/restore-db.sh:19-20`はUnix permission表現と文字列一致だけに依存する。Windows ACLで本人以外の読み取りを拒否できているか、またservice fileの後勝ち設定で実接続先が変わらないかを確認しない。Windows実機で、隔離先は通過し、本番先・ACL不備・重複hostは拒否される試験が必要。

### 中: 復旧可能性のE2E根拠が不足

Storageの空配列/scratch cleanupはコードで確認できたが、1000/1001件ページ境界、実age暗号化・復号、実OpenSSL署名検証、R2同型treeからのinspectはテストされていない。`run-tests.sh`も独立実行で15秒以内に完走しなかったため、STATEの21件合格を受容根拠にできない。

### 低: Storage無効時にもService Role credential fileを生成

workflow 87–97行のcredential準備はStorage設定に分岐しない。無効時には強力なStorage credentialをrunner一時ファイルへ出さないようにし、その分岐をテストする必要がある。

## 本番有効化前の条件（ユーザー判断を要するもの）

1. 上記中2件を是正し、独立担当がテスト全件、実age/OpenSSL、Storage 0/1000/1001件、R2同型tree→inspectを成功させること。
2. GitHubで`backup-scheduled`/`backup-manual`を既定branchに限定し、manualだけrequired reviewerにすること。repository-levelに対象Secretsを残さないこと。
3. Cloudflareでdaily 90日/monthly 400日のBucket Lock・Lifecycle、管理者分離、別媒体月次複製先を設定し、Rule ID・確認日・確認者を`docs/backup/recovery-inventory.md`へ記録すること。
4. 上記の外部設定はこの監査では未検証である。ユーザーが確認・受容するまでは、`R2_RETENTION_LOCK_CONFIRMED=true`を設定してworkflowを有効化しないこと。
