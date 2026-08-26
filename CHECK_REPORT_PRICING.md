# DAIDA+ 料金体系単純化 QA判定

監査日: 2026-08-26
対象:

- LP: `C:\Users\user\Documents\GitHub\daida-plus-lp`
- App: `C:\Users\user\Documents\GitHub\-shift-help-notify-app-`

## 総合判定

**不合格（本番へpush不可）**

公開中の導線から到達できる追跡済みLP `daida-homepage.html` に、廃止対象の旧料金条件が残っている。チラシ・FAX・アーカイブではなく、規約・特商法ページ等の「ホームに戻る」リンク先であるため、AC-5を満たさない。この旧LPはリリースキャンペーンの3か月無料も反映しておらず、料金・キャンペーン表示の整合も崩している。

主な不合格証拠:

- `C:\Users\user\Documents\GitHub\daida-plus-lp\daida-homepage.html:593` — 「月3回以上の代理募集…加入が必要」が残存。
- `C:\Users\user\Documents\GitHub\daida-plus-lp\daida-homepage.html:707` — 「無料期間終了後も、代理募集は月2回まで無料。月3回以上…有料プラン」が残存。
- `C:\Users\user\Documents\GitHub\daida-plus-lp\terms.html:97,183` および `tokushoho.html:109,204` — 上記旧LPへのリンク。`contact.html`、`news.html`、`privacy.html`にも同じリンクがある。

## AC判定

| AC | 判定 | 独立確認の証拠 |
|---|---|---|
| AC-1 | 合格 | `server.js:95-101,314-380`でJST固定のキャンペーン期間、既存店舗の2026-11-24終了、通常1か月を実装。`test/freeTrialCampaign.test.js:19-123`で開始・終了境界、既存店舗、月末クランプ、終了時刻ちょうどを固定時刻で検証。`npm test`成功。 |
| AC-2 | 合格 | `server.js:422-430`は無料期間または有効契約のみ許可。実Expressを使う`test/pricingAccess.test.js:139-181`で無料期間内・認識済み有料プラン中の募集作成成功を確認。 |
| AC-3 | 合格 | `server.js:1877-1894`で課金拒否が`shifts` INSERTより前。`test/pricingAccess.test.js:184-208`で既存募集があっても402、shift増加なし、`subscriptions`取得なしを確認。時間帯責任者についても同ファイル`314-341`で402・INSERTなし・通知取得なし・push呼出なしを確認。募集作成APIはメール送信を行わず、push通知もこの拒否経路には到達しない。 |
| AC-4 | 合格 | `server.js:314-319,358-365`で`skip_free_trial`は登録時刻に終了扱い。`test/freeTrialCampaign.test.js:73-80`と`test/pricingAccess.test.js:149-164`で2店舗目相当の即時拒否を検証。 |
| AC-5 | **不合格** | 現行`index.html`、アプリ画面、規約・特商法の更新自体は正しい。しかし、追跡済みで規約・特商法からリンクされる`daida-homepage.html:593,707`に旧「月2回まで無料／月3回以上有料」が残る。チラシ・FAXは検索対象外にしたが、このファイルは対象外ではない。 |
| AC-6 | **不合格** | `server.js:62-71`、`public/manager.html:334-350`、`index.html:590-607`、`tokushoho.html:159-169`の980円／2,352円／5,880円と3 Stripe Price ID対応は一致し、Stripe価格そのものの変更もない。一方、公開導線の旧LP `daida-homepage.html:593,707`は3か月無料と終了後有料契約必須の条件に一致しないため、LP全体での料金・条件整合は未達。 |
| AC-7 | 合格 | `server.js:1614-1634`は`trial` / `subscribed` / `subscription_required`を返し、旧残回数フィールドを返さない。`public/manager.html:1336-1371`も3状態を表示。`test/pricingAccess.test.js:210-243`が3状態と旧フィールド不存在を検証。 |
| AC-8 | **未検証** | Appの`npm test`は256/256成功、`npm run verify-sql`成功、両リポジトリの`git diff --check`成功、`server.js`・`manager.html`・`signup.html`・`index.html`のJavaScript構文検査成功。LPのアンカーは`#features`、`#how`、`#pricing`、`#compare`、`#faq`すべて存在し、相対リンク先も存在する。静的CSSでは幅560px以下で料金カード等が1列となり、比較表は横スクロールとなる（`index.html:285-293,333-343`）。ただし、Chrome/Edgeのヘッドレス描画はこの実行環境のGPU/プロファイル制限で起動できず、実ブラウザでのモバイル視覚確認は未実施。厳格基準では未検証として扱う。 |
| AC-9 | 合格 | Appの既存未コミット印刷調整は保持されている。`public/manager.html:130-131`の`@page margin:0`と`#printSheet`内側余白、`scripts/verify-print-layout.py:52-54,107-111,145-149`の同一前提が残る。料金変更は`public/manager.html:807-814,1336-1371`の別hunkで、印刷余白調整を上書きしていない。 |
| AC-10 | **不合格** | `STATE_PRICING.md`、更新済みAGENTS、App README/WORKLOGは実装と一致する。だが、公開導線にある`daida-homepage.html`が旧仕様のままで、仕様文書・本番表示の同期という受け入れ条件を満たさない。今回変更分に秘密情報は見つからず、`git diff --check`も成功。 |

## 必須観点の確認

### 課金・権限・Stripe

- 無料期間内、終了直前、終了時刻ちょうど、通常1か月、キャンペーン3か月、既存店舗の特例、`skip_free_trial`をテスト済み。
- 認識済みStripe 3プランは`test/pricingAccess.test.js:254-269`、未知Price IDのfail-closedは同`:272-302`で検証。実装は`server.js:373-415`。
- オーナーと時間帯責任者は同じ`requireAdmin`後の課金ゲートを通る。時間帯責任者の未契約直叩き、無料期間中、有料契約中を`test/pricingAccess.test.js:314-370`で検証。
- 課金拒否はshift INSERT、通知購読取得、push送信より前にある。上記テストは副作用がないことを確認している。
- 先着確定の処理・認証認可は今回の課金差分で変更されていない。全テストの先着・認証系回帰は成功した。

### 旧条件・価格の検索

- Appの`server.js`、`public/`、`README.md`、`AGENTS.md`には旧条件の実装・表示残存なし（テスト名の説明文を除く）。
- `index.html`、`terms.html`、`tokushoho.html`、`AI-HANDOFF.md`、`STATE_PRICING.md`には旧条件の実装・表示残存なし。
- ただし上記不合格証拠どおり、LPの追跡済み`daida-homepage.html`には残存する。これはFAX/チラシ資産ではない。

### テストの実効性

- 新規`test/pricingAccess.test.js`は空assertやskipではない。`buildApp()`で構築する実ExpressルートにHTTPリクエストを送り、フェイクSupabaseの`shifts`配列とテーブルアクセス履歴、注入したpush関数を検査している。
- `npm test`: 256 pass / 0 fail / 0 skipped / 0 todo。
- `npm run verify-sql`: setup.sql全文実行、テーブル/RPC/権限/主要RPC実行が成功。
- `npm audit --omit=dev`はnpmレジストリへの接続失敗で完走不可。これは今回の必須テストではないが、依存関係監査はネットワーク復旧後に別途再実行を推奨する。

## 本番へ出す前の必須是正

1. `daida-homepage.html`の料金・FAQ旧条件を、`index.html`と同じ新仕様へ更新するか、公開導線から完全に除外する。
2. `terms.html`、`tokushoho.html`、`contact.html`、`news.html`、`privacy.html`のホームリンクを、実際の正本LPへ統一する。リンク先を残すなら上記旧LPの更新が必要。
3. 是正後、旧条件の全文検索を再実行し、実ブラウザでLPをスマホ幅表示して確認する。
4. `npm test`、`npm run verify-sql`、両リポジトリの`git diff --check`を再実行してから再判定する。

この是正と再検証が完了するまで、LP・Appともcommit/pushしないこと。
