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

## 写真の差し替え

表面の写真エリアはプレースホルダーです。実写真を `assets/staff-photo-main.jpg`（推奨960 x 1400px）として用意し、`front.html` の `.photo-placeholder` を画像要素へ差し替えてください。

## スコープ外の確認事項

キャンペーン中に「月3回以上」の課金判定を発火させないアプリ側ロジックとの整合確認は、本チラシ実装の対象外です。アプリ本体リポジトリで別途確認してください。
