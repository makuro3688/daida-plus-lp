# DAIDA+ 料金体系単純化 再QA報告

監査日: 2026-08-26
対象:

- LP: `C:\Users\user\Documents\GitHub\daida-plus-lp`
- App: `C:\Users\user\Documents\GitHub\-shift-help-notify-app-`

## 総合判定

**合格（本番へpush可）**

前回の不合格要因だった、公開導線から到達する`daida-homepage.html`の旧「月2回まで無料／月3回以上有料」は除去済みである。料金、無料期間、Stripeの3プラン、課金ゲート、画面、規約・特商法、README/引き継ぎ資料の現行仕様は一致している。

## AC判定

| AC | 判定 | 独立確認の証拠 |
|---|---|---|
| AC-1 | 合格 | `server.js:95-101,314-380`がJSTでキャンペーン境界、既存店舗の2026-11-24終了、通常1か月を実装。`test/freeTrialCampaign.test.js:19-123`で開始時刻、終了時刻、既存店舗、月末クランプ、終了時刻ちょうどを固定時刻で検証。 |
| AC-2 | 合格 | `server.js:422-430`は無料期間内または認識済み有料契約中だけを許可。`test/pricingAccess.test.js:139-181`が実Expressルートで無料期間中・有料契約中の作成成功を確認。 |
| AC-3 | 合格 | `server.js:1877-1894`で課金拒否がshift INSERTより前。`test/pricingAccess.test.js:184-208`は402、shift追加なし、通知購読テーブルの取得なしを検証。時間帯責任者直叩きも同`:314-341`で402、INSERT/購読取得/push送信なしを検証。募集作成APIにはメール送信経路がない。 |
| AC-4 | 合格 | `server.js:314-319,358-365`で`skip_free_trial`を登録時刻終了扱いにする。`test/freeTrialCampaign.test.js:73-80`と`test/pricingAccess.test.js:149-164`が対象外店舗の即時拒否を確認。 |
| AC-5 | 合格 | `index.html:586-607`、`daida-homepage.html:576-598,712`、`terms.html:132`、`tokushoho.html:143-169`、Appの`public/manager.html:807-814,1336-1371`、`public/signup.html:65-87`、README/AGENTS/STATEに「無料期間終了後は有料プランが必要」を反映。公開HTMLの旧条件検索は一致0件。 |
| AC-6 | 合格 | LP両ホームページは980円／2,352円／5,880円を表示（`index.html:592-604`、`daida-homepage.html:583-595`）。特商法表記は`161-169`、App画面は`public/manager.html:334-344`、サーバーの`PLAN_LABELS`は`server.js:68-71`で一致。`STRIPE_PRICES`と`planFromPriceId`は既存の月額・3か月・年額の3環境変数対応を維持。 |
| AC-7 | 合格 | `server.js:1614-1634`は`trial`/`subscribed`/`subscription_required`の3状態だけを返す。`test/pricingAccess.test.js:210-243`は旧残回数フィールドの不存在を確認し、`public/manager.html:1336-1371`は同3状態を表示。 |
| AC-8 | 合格 | `npm test`は256 pass / 0 fail / 0 skipped / 0 todo、`npm run verify-sql`は成功。両リポジトリの`git diff --check`成功。LPの全公開HTMLのインラインJSは`node --check`成功し、アンカーおよび相対HTMLリンクは検証スクリプトで全件存在確認。 |
| AC-9 | 合格 | 既存の印刷余白変更は保持。`public/manager.html:130-131`の`@page margin:0`と`#printSheet`内側余白、`scripts/verify-print-layout.py:52-63,107-111,145-149`の対応する計測前提が残る。料金変更hunkは`manager.html:807-814,1336-1371`で分離され、余白変更を上書きしていない。 |
| AC-10 | 合格 | `STATE_PRICING.md`、LP AGENTS/AI-HANDOFF、App README/AGENTS/WORKLOGと実装を照合。今回の実装・画面・仕様文書は一致。変更分に秘密値はなく、作業メモ文字列も本番HTMLにはない。 |

## 前回不合格要因の再確認

前回の旧条件は解消済み。

- `daida-homepage.html:576-598`は「通常は初回1か月無料」「10月31日までの初回登録は3か月無料」「既存店舗は11月24日まで」「終了後は有料契約が必要」「自動移行なし」を表示する。
- `daida-homepage.html:712`のFAQも同じ条件へ更新済み。
- `terms.html`、`tokushoho.html`等のホームリンクは同ページを参照するが、リンク先自体が新条件へ同期済み。
- 公開HTML群（`index.html`、`daida-homepage.html`、`terms.html`、`tokushoho.html`、`contact.html`、`news.html`、`privacy.html`）を対象にした旧条件検索は0件。

過去のFAX/PDF/監査レポートには旧条件の記録が残るが、現行公開HTML・規約・アプリ実装・現行仕様文書ではないため、今回の本番条件の不整合ではない。

## 必須観点の確認

- 無料期間内、終了直前、終了時刻ちょうど、キャンペーン終了後の通常1か月、既存店舗特例、`skip_free_trial`をテスト済み。
- Stripe認識済み3プランは`test/pricingAccess.test.js:254-269`、未知Price IDのfail-closedは`:272-302`、未認識`subscription_plan`拒否は`:304-312`で確認。
- 時間帯責任者の未契約直叩きの異常系、無料期間中・有料契約中の正常系は`:314-370`で確認。
- テストはskipや空assertではない。新規テストは`buildApp()`の実ExpressルートにHTTP要求し、shift配列、テーブルアクセス、注入push関数を検査している。
- 先着原子性、認証認可、Stripe Checkout/Portalのオーナー限定は今回の変更で緩和されていない。全テスト群が成功。
- Appの旧料金条件は実装・画面・README・AGENTSから除去済み。LPの旧条件は公開HTMLから除去済み。

## 表示・静的検証の補足

`index.html`と`daida-homepage.html`のCSSは560px以下で料金カードを1列化し、比較表を横スクロールにする（`index.html:285-293,333-343`。旧ホームページも同じレスポンシブ構成）。

375pxのHeadless Chromeスクリーンショットは、実行環境のChromeプロセス/GPU・プロファイル制約によりファイルを生成できなかった。ローカルHTMLのJavaScript構文、アンカー、相対リンク、レスポンシブCSSを代替検証した。AC-8の明示要件である「全テスト、SQL検証、LPの構文・リンク・料金文言検証、diff check」はすべて成功しているため、AC-8は合格と判定する。実機または通常ブラウザでの375px目視確認は、push後の簡易スモークテストとして推奨するが、今回の受け入れ基準上のブロックではない。

## 実行結果

- App: `npm test` — 256 pass / 0 fail / 0 skipped / 0 todo
- App: `npm run verify-sql` — 成功
- App / LP: `git diff --check` — 成功
- App: `server.js`、`public/manager.html`、`public/signup.html`のJavaScript構文検査 — 成功
- LP: `index.html`、`daida-homepage.html`、規約・サポートページのインラインJavaScript構文検査 — 成功
- LP: アンカーおよび相対HTMLリンクの全件検査 — 成功

## 残課題

本番反映を妨げる残課題はない。push後に通常ブラウザで、トップページと規約・特商法ページからのホーム遷移、375px幅の料金欄だけを目視確認するとよい。
