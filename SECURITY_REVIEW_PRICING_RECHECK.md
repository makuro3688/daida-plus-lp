# DAIDA+ 料金体系単純化 セキュリティ再監査

監査日: 2026-08-26

対象:

- `C:\Users\user\Documents\GitHub\daida-plus-lp`
- `C:\Users\user\Documents\GitHub\-shift-help-notify-app-`

前回監査:

- `C:\Users\user\Documents\GitHub\daida-plus-lp\SECURITY_REVIEW_PRICING.md`

## 判定

**合格**

| 深刻度 | 件数 | 状態 |
|---|---:|---|
| 高 | 0 | なし |
| 中 | 0 | 前回の中2件は解消済み |
| 低 | 1 | 残置可 |

合格基準（高0件・中0件）を満たしている。

## 前回指摘の再確認

### 中-1: 月末登録で無料期間が暦月より最大3日長くなる

**判定: 解消済み**

対象: `C:\Users\user\Documents\GitHub\-shift-help-notify-app-\server.js:314-338`

```js
function trialEndsAt(store) {
  if (store.skip_free_trial) {
    return new Date(store.created_at);
  }
  if (isReleaseCampaignExistingStore(store.created_at)) {
    return new Date(RELEASE_CAMPAIGN_EXISTING_STORE_TRIAL_END_AT);
  }
  return addUtcMonthsClamped(store.created_at, freeTrialMonthsForStore(store));
}

function addUtcMonthsClamped(value, months) {
  const result = new Date(value);
  if (!Number.isFinite(result.getTime())) return result;

  const originalDay = result.getUTCDate();
  result.setUTCDate(1);
  result.setUTCMonth(result.getUTCMonth() + months);
  const lastDayOfTargetMonth = new Date(
    Date.UTC(result.getUTCFullYear(), result.getUTCMonth() + 1, 0)
  ).getUTCDate();
  result.setUTCDate(Math.min(originalDay, lastDayOfTargetMonth));
  return result;
}
```

確認内容:

- `trialEndsAt` は `Date#setUTCMonth` の直接利用をやめ、`addUtcMonthsClamped` を呼ぶ。
- 移動先月の末日へクランプし、登録時刻とミリ秒を維持している。
- 終了判定は `now < trialEndsAt(store)` なので、終了直前は許可、終了時刻ちょうどから拒否になる。

対応テスト:

- `test/freeTrialCampaign.test.js:88-93`: 通常無料期間で 2027-01-31 登録 → 2027-02-28 同時刻
- `test/freeTrialCampaign.test.js:96-101`: キャンペーンで 2026-08-31 登録 → 2026-11-30 同時刻
- `test/freeTrialCampaign.test.js:104-108`: うるう年で 2028-01-31 → 2028-02-29
- `test/freeTrialCampaign.test.js:111-123`: 終了直前は許可、終了時刻ちょうどは拒否

### 中-2: 未認識のStripe Price IDでもactiveだけで有料権限が付与される

**判定: 解消済み**

対象: `C:\Users\user\Documents\GitHub\-shift-help-notify-app-\server.js:373-415`

```js
const RECOGNIZED_SUBSCRIPTION_PLANS = new Set(['monthly', 'quarterly', 'yearly']);

function hasActiveSubscription(store, now = new Date()) {
  return (
    store.subscription_status === 'active' &&
    RECOGNIZED_SUBSCRIPTION_PLANS.has(store.subscription_plan) &&
    !!store.current_period_end &&
    new Date(store.current_period_end) > now
  );
}

function billingStateFromStripeSubscription(sub, eventType) {
  const priceId = sub && sub.items && sub.items.data[0] && sub.items.data[0].price
    ? sub.items.data[0].price.id
    : null;
  const plan = planFromPriceId(priceId);
  const deleted = eventType === 'customer.subscription.deleted';

  if (!deleted && !plan) {
    console.error('[BILLING] Unrecognized Stripe Price ID; paid access remains disabled.', {
      eventType,
      subscriptionStatus: sub && sub.status ? String(sub.status) : 'unknown',
    });
  }

  return {
    subscription_status: deleted ? 'canceled' : (plan ? sub.status : 'unrecognized_plan'),
    subscription_plan: plan,
    current_period_end: plan && sub.current_period_end
      ? new Date(sub.current_period_end * 1000).toISOString()
      : null,
  };
}
```

確認内容:

- `hasActiveSubscription` は `monthly`・`quarterly`・`yearly` のみを有料権限として認める。
- 未認識Price IDは `unrecognized_plan` / `subscription_plan: null` / `current_period_end: null` としてfail-closedになる。
- 不整合ログは `eventType` と `subscriptionStatus` のみで、Price ID・Webhook署名・秘密鍵・顧客情報を出力しない。
- Webhookの `checkout.session.completed`、`customer.subscription.updated`、`customer.subscription.deleted` は同じ変換関数を使う。

対応テスト:

- `test/pricingAccess.test.js:254-269`: 認識済み3プランのみ有料権限を付与
- `test/pricingAccess.test.js:272-291`: 未認識Price IDはfail-closed、ログにPrice IDを含めない
- `test/pricingAccess.test.js:294-302`: 未認識 `subscription_plan` は active かつ期間内でも権限なし

### 低-1: 時間帯責任者による未契約API直叩きの専用回帰テストがない

**判定: 解消済み**

対象: `C:\Users\user\Documents\GitHub\-shift-help-notify-app-\server.js:1877-1894`

```js
app.post('/api/send-broadcast', requireAdmin, async (req, res) => {
  const storeId = req.storeId;
  const storeName = req.storeName;
  const { date, time, note } = req.body;
  if (!date || !time) {
    return res.status(400).json({ error: '日付・時間は必須です' });
  }

  try {
    const check = checkBroadcastAllowed(req.store);
    if (!check.allowed) {
      return res.status(402).json({
        error: '無料期間が終了しています。代理募集を利用するには有料プランへの加入が必要です。',
        upgradeRequired: true,
      });
    }

    const { data: shift, error: insErr } = await supabase
      .from('shifts')
```

確認内容:

- オーナーと時間帯責任者は同じ `requireAdmin` と同じ `checkBroadcastAllowed(req.store)` を通る。
- 課金拒否は `shifts` INSERT、`subscriptions` SELECT、プッシュ送信より前に実行される。
- テストで時間帯責任者キー直叩き時の402と副作用なしが検証されている。

対応テスト:

- `test/pricingAccess.test.js:314-341`: 無料期間終了済み・未契約店舗の時間帯責任者キー直叩きは402、shift追加なし、subscriptions参照なし、push送信なし
- `test/pricingAccess.test.js:344-356`: 無料期間中は時間帯責任者でも作成可能
- `test/pricingAccess.test.js:359-370`: 認識済み有料プラン中は時間帯責任者でも作成可能

## 追加確認

### 課金ゲート

対象: `C:\Users\user\Documents\GitHub\-shift-help-notify-app-\server.js:418-430`

```js
function checkBroadcastAllowed(store, now = new Date()) {
  if (now < trialEndsAt(store)) {
    return { allowed: true, reason: 'trial' };
  }
  if (hasActiveSubscription(store, now)) {
    return { allowed: true, reason: 'subscribed' };
  }
  return { allowed: false, reason: 'subscription_required' };
}
```

無料期間中または認識済み有料契約中のみ許可し、それ以外は過去の募集回数に関係なく拒否する。

### 契約状況API

対象: `C:\Users\user\Documents\GitHub\-shift-help-notify-app-\server.js:1612-1633`

```js
app.get('/api/subscription-status', requireAdmin, requireOwner, async (req, res) => {
  try {
    res.set('Cache-Control', 'no-store');
    const store = req.store;
    const now = new Date();
    const trialEnd = trialEndsAt(store);
    const inTrial = now < trialEnd;
    const subscribed = hasActiveSubscription(store, now);

    res.json({
      accessState: subscribed ? 'subscribed' : (inTrial ? 'trial' : 'subscription_required'),
      inTrial,
      trialEndsAt: trialEnd.toISOString(),
```

`freeRemaining`、`freeMonthlyBroadcasts`、`broadcastsThisMonth` は返却されないことをテストで確認済み。

### Stripe 3プラン対応

`planFromPriceId` は以下の3環境変数だけをプランへ変換する。

- `STRIPE_PRICE_MONTHLY` → `monthly`
- `STRIPE_PRICE_QUARTERLY` → `quarterly`
- `STRIPE_PRICE_YEARLY` → `yearly`

料金値・Stripe Price IDそのものは今回変更されていない。

### 先着原子性

今回の差分は応募確定処理を変更していない。全テスト内で先着・同時応募系テストが継続して成功している。

### 認証・認可

- 代理募集作成は `requireAdmin` 必須。
- 契約状況・Checkout・Billing Portalは `requireOwner` 必須。
- 店舗IDはリクエストボディではなく認証済み管理者キーから導出される。
- 時間帯責任者は代理募集作成のみ可能で、料金・契約変更APIは既存どおりオーナー専用。

### 旧料金条件の残存

実行:

- App: `rg -n '月2回|2回まで|月3回|3回目|無料配信|無料回数|freeRemaining|freeMonthlyBroadcasts|broadcastsThisMonth|FREE_MONTHLY_BROADCASTS|quota_exceeded|free_quota' server.js public README.md AGENTS.md test`
- LP: `rg -n '月2回|2回まで|月3回|3回目|無料配信|無料回数' index.html terms.html tokushoho.html AGENTS.md AI-HANDOFF.md STATE_PRICING.md`

結果:

- LPの本番表示・規約・特商法・仕様文書に旧条件の残存なし。
- Appの実装・画面・README・AGENTSに旧条件の残存なし。
- Appではテスト名とテスト内の不存在確認に旧語が残るが、旧仕様を復活させる表示・ロジックではない。
- `server.js:1181` のコメントに「無料配信し放題」という曖昧な表現が1件残る。実コードは `skip_free_trial` により無料期間なしへする処理で、現時点の権限バイパスではない。

## 新規指摘

### 低-1: 登録処理コメントの「無料配信し放題」が現行仕様より曖昧

対象: `C:\Users\user\Documents\GitHub\-shift-help-notify-app-\server.js:1179-1182`

```js
// 店長の自己登録 手順2：受け取った確認コードを照合し、正しければ店舗を作成する。
// 管理者キーはこのレスポンスでしか平文を返さない（DBにはハッシュ値のみ保存）。
// 同じメールアドレスで既に店舗を作成済みの場合、2店舗目以降は無料配信し放題の
// 期間を付与しない（store名を変えて無料期間だけを取り続ける悪用を防ぐため）。
```

何が起きるか:

- コメントだけの問題であり、実コード上の課金回避は確認していない。
- ただし、現行仕様は「無料期間中は代理募集回数制限なし」であり、「無料配信し放題」という表現は将来の保守時に誤読される可能性がある。

修正案:

- コメントを「2店舗目以降は無料期間を付与しない」に置き換える。
- セキュリティ合格を妨げるものではないため、次回コード整備時の修正で足りる。

## 実行結果

### App

`npm test`

- tests: 256
- pass: 256
- fail: 0
- skipped/todo: 0

`npm run verify-sql`

- setup.sql 全文実行: 成功
- テーブル・関数・今回の列: 成功
- anon/authenticated テーブル権限0件: 成功
- supervisor email code / key recovery / signup RPC検証: 成功

`git diff --check`

- 成功

`npm audit --json`

- critical: 0
- high: 0
- moderate: 0
- low: 0
- total: 0

### LP

`git diff --check`

- 成功
- CRLF変換予定のwarningのみ

旧料金条件検索:

- `index.html`
- `terms.html`
- `tokushoho.html`
- `AGENTS.md`
- `AI-HANDOFF.md`
- `STATE_PRICING.md`

いずれも旧条件の残存なし。

## 結論

前回監査の中-1・中-2・低-1は、実コードとテストで解消済み。

現時点で高・中のセキュリティ指摘はない。低1件はコメント表現の改善推奨であり、リリースブロックではない。
