# DAIDA+ flyer

A4表面・裏面のHTMLテンプレートと、印刷用PNG/PDFの書き出し環境です。既存LPやアプリ本体のコードには依存しません。

## 書き出し

```bash
cd flyer
npm install
node export.mjs
```

リポジトリ直下から `node flyer/export.mjs` を実行することもできます。成果物は `flyer/dist/` に生成されます。

- `daida-flyer-front.png` / `daida-flyer-back.png`: A4・300dpi相当
- `daida-flyer-front.pdf` / `daida-flyer-back.pdf`: A4・余白0・背景色を含む印刷用PDF

QRコードは書き出し時に `https://daida-store.jp` から生成します。UTMパラメータは付けていません。

## 表面写真

表面では `assets/staff-photo-main.jpg` を使用します。人物や背景を再生成・加工せず、元JPGをHTML上で拡大縮小・配置しています。

## アプリ側との整合

無料期間終了後に代理募集を利用するには有料プランへの加入が必要です。チラシの書き出し環境はLPリポジトリ内で完結し、アプリ本体の課金ロジックには依存しません。
