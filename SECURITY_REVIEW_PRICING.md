# DAIDA+ 料金体系単純化 セキュリティ独立監査

監査日: 2026-08-26
対象計画: `行動計画書_DAIDA料金体系単純化_20260826.md`
対象リポジトリ: `daida-plus-lp` / `-shift-help-notify-app-`

## 判定

**不合格（修正後に再監査が必要）**

| 深刻度 | 件数 |
|---|---:|
| 高 | 0 |
| 中 | 2 |
| 低 | 1 |

高は0件だが、中2件が未修正であるため、計画の合格基準を満たしていない。

## 指摘

### 中-1: 月末登録では無料期間が暦月より最大3日長くなり、未契約でも募集を作成できる

対象: `C:\Users\user\Documents\GitHub\-shift-help-notify-app-\server.js:321-323`

```js
  const end = new Date(store.created_at);
  end.setUTCMonth(end.getUTCMonth() + freeTrialMonthsForStore(store));
  return end;
```

`Date#setUTCMonth`は、移動先の月に同じ日が存在しない場合、翌月へ日付を繰り上げる。実コードと同じ計算を実行した結果は次のとおりだった。

- `2026-08-31T00:00:00.000Z` + 3か月 → `2026-12-01T00:00:00.000Z`（11月30日ではなく1日延長）
- `2027-01-31T00:00:00.000Z` + 1か月 → `2027-03-03T00:00:00.000Z`（2月28日ではなく3日延長）

攻撃手順:

1. 通常キャンペーンまたは通常無料期間で、月末（例: 1月31日）に初回店舗登録を完了する。
2. 本来の翌月末を過ぎてから、オーナーまたは時間帯責任者の管理者キーで `POST /api/send-broadcast` を直接呼ぶ。
3. `trialEndsAt`が3月3日を返し、`checkBroadcastAllowed`が`reason: 'trial'`として許可する。
4. 有料契約がなくても、最大3日間、募集レコード作成と通知送信が可能になる。

影響:

- 「登録日から1か月／3か月」という料金条件より無料利用が延びる。
- 無料期間境界の課金ゲートをAPIから回避できる。
- 現在のテストはキャンペーン開始・終了時刻を確認しているが、月末加算の繰り上がりを検出しない。

具体的修正案:

- 元の日を保存し、移動先月の末日と比較して小さい方へ丸める`addUtcMonthsClamped`を実装する。
- `trialEndsAt`では`setUTCMonth`を直接使わず、その関数を呼ぶ。
- 少なくとも次の固定時刻テストを追加する。
  - 通常: 2027年1月31日登録 → 2027年2月28日の同時刻で終了
  - キャンペーン: 2026年8月31日登録 → 2026年11月30日の同時刻で終了
  - うるう年: 2028年1月31日登録 → 2028年2月29日の同時刻で終了
  - 終了直前は許可、終了時刻ちょうどは拒否

### 中-2: 未認識のStripe Price IDでも`active`だけで有料権限が付与される

対象: `C:\Users\user\Documents\GitHub\-shift-help-notify-app-\server.js:358-363`

```js
function hasActiveSubscription(store) {
  return (
    store.subscription_status === 'active' &&
    !!store.current_period_end &&
    new Date(store.current_period_end) > new Date()
  );
}
```

対象: `C:\Users\user\Documents\GitHub\-shift-help-notify-app-\server.js:869-878`

```js
const storeId = sub.metadata && sub.metadata.store_id;
if (storeId) {
  const plan = sub.items && sub.items.data[0] ? planFromPriceId(sub.items.data[0].price.id) : null;
  await supabase
    .from('stores')
    .update({
      subscription_status: event.type === 'customer.subscription.deleted' ? 'canceled' : sub.status,
      subscription_plan: plan,
      current_period_end: sub.current_period_end ? new Date(sub.current_period_end * 1000).toISOString() : null,
```

`planFromPriceId`が未認識Price IDに対して`null`を返しても、Webhookは`subscription_status: 'active'`と将来の終了日時を保存する。`hasActiveSubscription`は`subscription_plan`を検証しないため、その店舗へ有料権限を付与する。

攻撃手順（Stripe Customer Portalに未認識の安価・無料・旧Priceが選択可能な構成の場合）:

1. 店舗オーナーが正規の請求ポータルを開く。
2. ポータルで、環境変数の3つのPrice IDに含まれない旧Price等へ契約を変更する。
3. `customer.subscription.updated`により、DBには`subscription_plan: null`、`subscription_status: active`、将来の`current_period_end`が保存される。
4. オーナーまたは時間帯責任者が `POST /api/send-broadcast` を呼ぶと、`hasActiveSubscription`が真になり募集が許可される。

影響:

- Stripe側に選択可能な未認識Priceが1つでも残っていると、確定料金を支払わず有料機能を利用できる。
- コードからStripe Customer Portalの実設定は確認できないため、現在の本番で悪用可能かは未検証。ただしサーバー側がfail-openであるため、設定ミス1つで課金回避になる。

具体的修正案:

- `hasActiveSubscription`に、`subscription_plan`が`monthly`、`quarterly`、`yearly`のいずれかであることを追加する。
- Webhookで`planFromPriceId`が`null`なら有料権限を有効化せず、運用者向けにPrice ID不整合を記録する。ログには秘密鍵やWebhook署名を出さない。
- 修正前に本番Stripeの3つのPrice IDと既存DBの`subscription_plan`を照合し、正規の契約者を誤停止させない。
- 未認識Priceかつ`active`は募集拒否、3つの認識済みPriceは許可、というテストを追加する。
- Customer Portal側でも契約変更候補を確定3プランだけに制限する。

### 低-1: 時間帯責任者による未契約API直叩きの専用回帰テストがない

対象: `C:\Users\user\Documents\GitHub\-shift-help-notify-app-\test\pricingAccess.test.js:70-75`

```js
if (table === 'stores') {
  return { select: () => chain(stores) };
}
if (table === 'supervisor_keys') {
  return { select: () => chain([]) };
}
```

現在の`pricingAccess.test.js`は`supervisor_keys`を常に空で返すため、課金ゲートの全ケースがオーナーキー経路だけを通る。実装本体では`requireAdmin`が時間帯責任者にも同じ`req.store`を設定し、同じ`checkBroadcastAllowed(req.store)`を通すため、静的確認上の迂回は成立しない。しかし重点監査項目に対する直接の回帰テストが欠けている。

攻撃手順／確認手順:

1. 無料期間終了済み・未契約店舗に時間帯責任者キーを発行する。
2. オーナー用画面の表示に依存せず、そのキーを`x-admin-key`へ設定して `POST /api/send-broadcast` を直接呼ぶ。
3. 現在のコードでは402になる見込みだが、この経路を自動テストが証明していない。

影響:

- 今後オーナーと時間帯責任者の分岐を変更した際、時間帯責任者だけ課金ゲートを迂回する回帰をCIが検出できない。
- 現時点で成立する課金回避は確認していない。

具体的修正案:

- フェイクSupabaseへ`supervisor_keys`行を渡せるようにし、未契約・無料期間終了済み店舗の時間帯責任者キーで402になるテストを追加する。
- 同じテストで`shifts` INSERTなし、`subscriptions` SELECTなし、プッシュ送信なしを確認する。
- 対比として、無料期間中および認識済み有料プラン中は時間帯責任者でも作成可能であることを確認する。

## 確認できた防御

### API直接呼び出しと時間帯責任者経路

`POST /api/send-broadcast`は`requireAdmin`を必須とし、店舗IDをリクエストボディから受け取っていない。時間帯責任者も認証キーから導出された店舗行を`req.store`に受け取り、同じ課金判定へ進む。

```js
app.post('/api/send-broadcast', requireAdmin, async (req, res) => {
  const storeId = req.storeId;
  const storeName = req.storeName;
  const { date, time, note } = req.body;
```

### 課金ゲートの順序

拒否判定は`shifts` INSERT、通知先の`subscriptions` SELECT、プッシュ送信より前にある。新規テストでも拒否時のINSERTなし・通知先取得なしを確認している。

```js
const check = checkBroadcastAllowed(req.store);
if (!check.allowed) {
  return res.status(402).json({
    error: '無料期間が終了しています。代理募集を利用するには有料プランへの加入が必要です。',
    upgradeRequired: true,
  });
}
```

### 2店舗目・退会後再登録

`skip_free_trial`はクライアント入力ではなく、確認済みメールアドレスについて既存店舗と`used_emails`をサーバー側で照合して決め、課金判定でも最優先で無料期間終了扱いにしている。

### 契約状況API

`/api/subscription-status`は`requireAdmin, requireOwner`で保護され、`freeRemaining`、`freeMonthlyBroadcasts`、`broadcastsThisMonth`を返さない。今回追加されたテストでも3フィールドの不存在を確認している。

### Stripeプラン定数とWebhook署名

3つの料金表示と環境変数Price ID対応は変更されていない。WebhookはJSONパーサーより前でraw bodyを受け取り、`STRIPE_WEBHOOK_SECRET`による署名検証を維持している。

### 先着確定・認証認可

応募確定は引き続き`id`と`status = 'open'`の両方を条件にした単一UPDATEで、今回の差分に変更はない。オーナー専用の料金・Checkout・Billing Portal APIには`requireOwner`が維持されている。

### 秘密情報とログ

変更差分とリポジトリを、Stripe live key、Webhook secret、Supabase service key代入、Resend key代入、秘密鍵ヘッダーの代表パターンで検索し、実値らしき一致はなかった。テスト用ダミー文字列と環境変数名のみ確認した。今回の変更に秘密値を出力するログ追加はない。

## 実行結果

- `npm test`: **246件すべて成功**
- `npm run verify-sql`: **成功**。`anon` / `authenticated`のテーブル権限0件を含む全項目成功
- アプリ `git diff --check`: **成功**
- LP `git diff --check`: **成功**（CRLF変換予定のwarningのみ）
- 旧料金条件の対象ファイル検索: 本番表示・規約・確定仕様ファイルに残存なし
- `npm audit --json`: **未検証**。npm registryのaudit endpointへの接続に失敗し、npm cacheログディレクトリへの書き込みも拒否されたため、脆弱性件数を取得できなかった

## スコープ分離

`public/manager.html`の印刷用内側余白変更と`scripts/verify-print-layout.py`の変更は、料金体系単純化より前から存在する未コミット差分として確認した。今回のセキュリティ判定には含めず、削除・変更もしていない。

## 再監査条件

1. 中-1の日付加算を月末クランプ方式へ変更し、月末・うるう年・終了境界のテストを追加する。
2. 中-2の有料権限判定を認識済みプランへ限定し、未認識Price IDをfail-closedにする。
3. 全テストとSQL検証を再実行する。
4. 低-1の時間帯責任者専用テストは今回あわせて追加することを推奨する。
