"""LPの写真②（photo2）に写っている「偽のQRコード」を、文字の入った四角に差し替える。

なぜ必要か
----------
photo2 に写っている貼り紙のQRは、**AIが描いた「QRっぽい模様」で、読み取れません。**
（3隅にあるはずの位置検出マークが右下にもあり、規格として成立していない）

このLPは「店舗用QRコードから登録できます」と説明している場所です。
興味を持った店長がスマホをかざしても、**何も起きません。**
最初に試すのが「動かない体験」になります。

そこで、QRの部分を「店舗ごとの QRコード」という文字に差し替えます。
**ぼかしではなく文字にするのは、「見本である」と言い切るためです。**

⚠️ 2か所あります
-----------------
1. 壁の貼り紙のQR（大きい・正面）
2. **スマホの画面に写っている、同じ貼り紙のQR（小さい）**

スマホはその貼り紙を撮影している画面です。**片方だけ直すと、
撮っている物と写っている物が食い違います。** 必ず両方直します。

⚠️ 出力は2ファイル
------------------
LPが使うのは `photo2.jpg` ですが、元データの `photo2.png` も直します。
**jpgだけ直すと、次に誰かがpngから作り直したとき偽QRが戻ってきます。**

使い方
------
    pip install opencv-python-headless pillow
    python scripts/replace_fake_qr_in_photo2.py

実行後、`--verify` で読み取り不能になったことを機械的に確認できます。
"""

import sys
from pathlib import Path

import cv2
import numpy as np
from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parents[1]
FONT_PATH = "/usr/share/fonts/opentype/noto/NotoSansCJK-Bold.ttc"

LINES = ["店舗ごとの", "QRコード"]

# 乗算合成する文字の色（BGR）。
# 紙の色 (203,209,216) に掛けると (119,66,21) ＝ 貼り紙の青枠とほぼ同じ濃紺になる。
# **べた塗りで置くのではなく掛け算にするのは、紙の陰影を残すため。**
TEXT_MUL_BGR = (150, 80, 25)


# 座標はすべて photo2（1536x1024）の実寸。
# fill  … 紙で塗りつぶす範囲（枠の内側。**青枠には絶対に触れない**よう内側に取る）
# text  … 文字を載せる四角（元のQRが占めていた範囲。傾きをそのまま引き継ぐ）
TARGETS = [
    {
        "name": "壁の貼り紙",
        "fill": [(268, 392), (430, 391), (428, 566), (268, 571)],
        "text": [(278, 401), (422, 401), (420, 548), (278, 557)],
        # ざらつきの強さを測る、何も印刷されていない紙の場所（青枠の上）
        "plain": (300, 340, 400, 372),
        "line_gap": 0.22,
    },
    {
        # 【2026-08-26 方針変更】最初は「画面の中の貼り紙のQRだけ」を差し替えた。
        # しかし tas さんの指摘どおり、**実際にQRを読むときは、
        # 他の情報が入らないようにQRだけを写す。**
        # 画面いっぱいに貼り紙全体（題字・説明文・黄色い帯）が写っているのは、
        # そもそも不自然だった。しかもそれらは全部、AIの描いたでたらめな文字。
        #
        # → **カメラが映している範囲は、紙の地色だけにする。**
        #    そこに「店舗ごとの QRコード」の四角だけを、近づいて撮った大きさで置く。
        "name": "スマホ画面",
        # カメラが映している範囲。
        # ⚠️ 目分量で決めて右端に元の背景が残った。**画面の黒い部分と地続きでない
        # 明るい塊**として取り出し、行ごとの右端を数えて求め直した値がこれ。
        # スマホが傾いているため、**4辺すべてが斜め**。四隅とも別々に測った
        # （右端 641→652、下端 x=560 で y=560・x=640 で y=553）。
        # 下辺を水平だと思って 554 で切ったところ、**下に元の背景が帯で残った。**
        "fill": [(543, 409), (641, 406), (652, 552), (553, 561)],
        # ⚠️ ここは 1次式（平面）で当てはめる。
        # 範囲が広く、元になる明るい画素が真ん中に偏っているため、
        # 2次式だと端が不自然に暗くなったり明るくなったりする。
        "order": 1,
        "frame": {"quad": [(560, 440), (634, 438), (632, 520), (561, 522)],
                  "bgr": (70, 60, 46)},
        "text": [(564, 445), (630, 443), (628, 516), (565, 518)],
        # ざらつきを測る、画面の中の貼り紙の何も無いところ
        "plain": (600, 452, 616, 457),
        "line_gap": 0.22,
    },
]


def poly_mask(shape, quad):
    m = np.zeros(shape[:2], np.uint8)
    cv2.fillConvexPoly(m, np.array(quad, np.int32), 255)
    return m


def erase_qr(img, quad, plain, order=2):
    """四角の中の模様（QR）を消して、紙だけにする。

    ⚠️ inpaint（周りから塗り広げる方法）は使わない。
    一度これで作ったところ、**四角い染みのようなムラ**が出た。
    紙には照明のムラ（左上が明るく右下が暗い、など）があり、
    塗り広げでは再現できない。

    代わりに、**いま写っている紙そのものから求める。**
    QRの白い隙間は、この四角の全面に散らばっている。
    その明るい画素だけを拾って、なだらかな曲面（2次式）を当てはめれば、
    照明のムラを含んだ「その場所の紙の色」が復元できる。
    """
    area = poly_mask(img.shape, quad)
    gray = cv2.cvtColor(img, cv2.COLOR_BGR2GRAY)

    # 明るい画素＝紙。QRの白い隙間と、コードの周りの余白。
    thr = np.percentile(gray[area > 0], 75)
    paper = (gray >= thr) & (area > 0)
    ys, xs = np.nonzero(paper)
    if len(ys) < 60:
        raise RuntimeError("紙の色を求めるだけの明るい画素が足りません")

    # 座標を -1〜1 に正規化してから当てはめる（桁が揃わないと解が荒れる）
    x0, x1 = xs.min(), xs.max()
    y0, y1 = ys.min(), ys.max()

    def basis(x, y):
        u = (x - x0) / max(x1 - x0, 1) * 2 - 1
        v = (y - y0) / max(y1 - y0, 1) * 2 - 1
        terms = [np.ones_like(u), u, v]
        if order >= 2:
            terms += [u * v, u * u, v * v]
        return np.stack(terms, axis=-1)

    A = basis(xs.astype(np.float64), ys.astype(np.float64))
    gy, gx = np.nonzero(area)
    B = basis(gx.astype(np.float64), gy.astype(np.float64))

    out = img.copy()
    for c in range(3):
        coef, *_ = np.linalg.lstsq(A, img[ys, xs, c].astype(np.float64), rcond=None)
        out[gy, gx, c] = np.clip(B @ coef, 0, 255)

    # 曲面はつるつるになる。写真の粒状感が無いと、そこだけ浮く。
    #
    # ⚠️ ざらつきの強さは、**何も印刷されていない紙の場所**から測る。
    # 一度、QRのあった範囲から測って失敗した。そこにはモジュールの黒い縁が
    # 混ざっているため、実際の何倍もの値になり、**砂嵐のような画面**になった。
    #
    # ⚠️ また、RGBそれぞれに別のざらつきを足してはいけない。
    # 色の粒（赤や緑の点々）が出る。**明るさだけを揺らす。**
    px0, py0, px1, py1 = plain
    patch = gray[py0:py1, px0:px1].astype(np.float64)
    sigma = min(float(np.std(patch - cv2.GaussianBlur(patch, (0, 0), 2))), 4.0)
    rng = np.random.default_rng(20260826)
    noise = rng.normal(0, max(sigma, 0.5), size=len(gy))[:, None]
    out[gy, gx] = np.clip(out[gy, gx].astype(np.float64) + noise, 0, 255)

    # 縁は1px ぼかして、外側の余白となめらかにつなぐ。
    alpha = (cv2.GaussianBlur(area, (0, 0), 1).astype(np.float32) / 255.0)[..., None]
    return (out * alpha + img * (1 - alpha)).astype(np.uint8)


def text_layer(w, h, line_gap):
    """白地に濃い文字の画像を作る（乗算合成用）。"""
    scale = 6
    W, H = w * scale, h * scale
    im = Image.new("L", (W, H), 255)
    d = ImageDraw.Draw(im)

    # 幅の78%に収まる最大の文字サイズを探す。
    # **決め打ちにしない。** 文言を変えたときに、はみ出したり小さすぎたりするため。
    size = 8
    while size < H:
        f = ImageFont.truetype(FONT_PATH, size + 1, index=0)
        widest = max(d.textlength(s, font=f) for s in LINES)
        total = (size + 1) * (len(LINES) + line_gap * (len(LINES) - 1))
        if widest > W * 0.78 or total > H * 0.62:
            break
        size += 1
    font = ImageFont.truetype(FONT_PATH, size, index=0)

    step = size * (1 + line_gap)
    block = step * (len(LINES) - 1) + size
    top = (H - block) / 2
    for i, s in enumerate(LINES):
        bbox = font.getbbox(s)
        x = (W - (bbox[2] - bbox[0])) / 2 - bbox[0]
        d.text((x, top + i * step - bbox[1]), s, font=font, fill=0)

    return np.array(im.resize((w, h), Image.LANCZOS))


def draw_text(img, quad, line_gap):
    xs = [p[0] for p in quad]
    ys = [p[1] for p in quad]
    w, h = max(xs) - min(xs), max(ys) - min(ys)

    layer = text_layer(w, h, line_gap)
    src = np.float32([(0, 0), (w, 0), (w, h), (0, h)])
    M = cv2.getPerspectiveTransform(src, np.float32(quad))
    warped = cv2.warpPerspective(
        layer, M, (img.shape[1], img.shape[0]),
        flags=cv2.INTER_LINEAR, borderMode=cv2.BORDER_CONSTANT, borderValue=255,
    ).astype(np.float32) / 255.0

    # 乗算合成。文字のあるところだけ、指定色の割合まで暗くなる。
    mul = np.stack([warped + (1 - warped) * (c / 255.0) for c in TEXT_MUL_BGR], axis=2)
    return np.clip(img.astype(np.float32) * mul, 0, 255).astype(np.uint8)


def draw_frame(img, spec):
    """消してしまった枠線を引き直す。

    はっきりした線をそのまま置くと、写真の中で**そこだけ妙にくっきり**する。
    軽くぼかしてから重ねて、周りのピントに合わせる。
    """
    # 角を丸める。壁の貼り紙の枠が角丸なので、画面に写る枠も角丸でないと食い違う。
    # 単位正方形の上で丸角の輪郭を作り、それを四角の傾きに合わせて写す。
    r = spec.get("radius", 0.07)
    pts = []
    for cx, cy, a0 in ((r, r, 180), (1 - r, r, 270), (1 - r, 1 - r, 0), (r, 1 - r, 90)):
        for k in range(9):
            a = np.radians(a0 + 90 * k / 8)
            pts.append((cx + r * np.cos(a), cy + r * np.sin(a)))
    unit = np.float32([(0, 0), (1, 0), (1, 1), (0, 1)])
    M = cv2.getPerspectiveTransform(unit, np.float32(spec["quad"]))
    pts = cv2.perspectiveTransform(np.float32(pts).reshape(-1, 1, 2), M)

    # ⚠️ 実寸のまま1画素の線を引くと、傾いた四角では**階段状のギザギザ**になる。
    # 4倍の大きさで描いてから縮める。
    s = 4
    big = np.zeros((img.shape[0] * s, img.shape[1] * s), np.float32)
    cv2.polylines(big, [np.int32(np.round(pts * s))], True, 1.0, s, cv2.LINE_AA)
    layer = cv2.resize(big, (img.shape[1], img.shape[0]), interpolation=cv2.INTER_AREA)
    layer = np.clip(cv2.GaussianBlur(layer, (0, 0), 0.6) * 1.6, 0, 1)[..., None]
    color = np.array(spec["bgr"], np.float32)
    return (img * (1 - layer) + color * layer).astype(np.uint8)


def verify(path):
    img = cv2.imread(str(path))
    ok, infos, _, _ = cv2.QRCodeDetector().detectAndDecodeMulti(img)
    found = [i for i in (infos or []) if i]
    if ok and found:
        print(f"  ❌ {path.name}: QRとして読み取れる内容が残っています: {found}")
        return False
    print(f"  ✅ {path.name}: 読み取れるQRなし")
    return True


def main():
    if "--verify" in sys.argv:
        return 0 if all(verify(ROOT / n) for n in ("photo2.jpg", "photo2.png")) else 1

    src = cv2.imread(str(ROOT / "photo2.png"))
    if src is None:
        print("photo2.png が見つかりません")
        return 1

    # ⚠️ この処理は「元の写真」に対して1回だけ実行するもの。
    # 差し替え後の写真にもう一度かけると、作った文字を消してさらに塗り直す。
    # 壁の貼り紙のQRがあった場所に暗い画素が残っているかで、未処理かを判定する。
    probe = cv2.cvtColor(src[405:545, 280:420], cv2.COLOR_BGR2GRAY)
    if (probe < 120).mean() < 0.15 and "--force" not in sys.argv:
        print("  ⚠️ photo2.png は差し替え済みに見えます。")
        print("     元に戻してから実行してください:  git checkout -- photo2.png photo2.jpg")
        return 1

    img = src.copy()
    for t in TARGETS:
        img = erase_qr(img, t["fill"], t["plain"], t.get("order", 2))
        if t.get("frame"):
            img = draw_frame(img, t["frame"])
        img = draw_text(img, t["text"], t["line_gap"])
        print(f"  差し替え: {t['name']}")

    cv2.imwrite(str(ROOT / "photo2.png"), img)
    # LPが読み込むのは jpg。
    # ⚠️ 品質は 95。88〜97 を試し、**触っていない部分が元の photo2.jpg と
    # いちばん近くなる値**を選んだ（差 RMSE 1.34／ファイル 417KB ≒ 元の 413KB）。
    # 下げるとページは軽くなるが、写真全体が知らないうちに劣化する。
    cv2.imwrite(str(ROOT / "photo2.jpg"), img, [cv2.IMWRITE_JPEG_QUALITY, 95])
    print("  photo2.png / photo2.jpg を更新しました")

    return 0 if all(verify(ROOT / n) for n in ("photo2.jpg", "photo2.png")) else 1


if __name__ == "__main__":
    sys.exit(main())
