"""DAIDA+ FAXチラシ（A4縦・黒1色）を生成する。

2026-08-25 改訂。専門家評価（FAXチラシ_専門家評価_20260825_初回.md）で
平均78.25点となった版を、合格条件10項目に沿って作り直したもの。

【この版で直したこと】
  1. キャンペーンの期限（2026年10月31日）を明記した
     紙は回収できない。期限の無い「3か月無料」は、11月に読まれた瞬間に
     事実と違う表示になる（景品表示法の有利誤認のおそれ）。
  2. 配信停止文の下に15mm以上の余白を確保した
     多くのFAX機は用紙下端5mm前後を印字しない。改訂前は下から2.0mmで、
     いちばん消えてはいけない「配信停止の案内」が消える位置にあった。
  3. すべての文字を10.5pt以上、URLを18pt以上にした
     改訂前は 9.0 / 9.6 / 10.0pt と 17.5pt が混在していた。
     標準FAXは縦解像度が横の半分しかなく、9ptは線が途切れる。
  4. 「先着で確定」を太枠で独立強調した（原案の指示に復帰）
  5. メインコピーと重複する「一人ずつ電話しなくていい」を削った
  6. 感嘆符をやめ、断定形にした（人事総務が社内で回覧できるトーン）
  7. 比較注記を1行にまとめた

【自動検査】
  この版から assert_* による自作検査を入れている。目視だけに頼ると、
  今回のように「一度合格した紙面が、追記のたびに静かに基準を割る」ことが起きる。
  MIN_PT を割る指定、枠からのはみ出し、下部余白不足は、
  生成時に例外で止まる。

【フォント】
  Windows では Meiryo を使う。それ以外の環境（検証用のLinux等）では
  Noto Sans CJK JP に自動で切り替える。字幅がわずかに異なるため、
  配布する PDF は必ず Windows 上で生成すること。
  ただし幅検査があるため、代替フォントでの検証でもはみ出しは検出できる。
"""

import os
from pathlib import Path

from reportlab.lib.pagesizes import A4
from reportlab.lib.units import mm
from reportlab.pdfbase import pdfmetrics
from reportlab.pdfbase.ttfonts import TTFont
from reportlab.pdfgen import canvas


ROOT = Path(__file__).resolve().parents[1]
OUTPUT = ROOT / "output" / "pdf" / "DAIDA_FAXチラシ.pdf"

# Windows（本番の生成環境）を第1候補、検証用のLinuxを第2候補にする。
FONT_CANDIDATES = [
    (Path(r"C:\Windows\Fonts\meiryo.ttc"), Path(r"C:\Windows\Fonts\meiryob.ttc"), 0, 0),
    (
        Path("/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc"),
        Path("/usr/share/fonts/opentype/noto/NotoSansCJK-Bold.ttc"),
        0,
        0,
    ),
]

PAGE_W, PAGE_H = A4
LEFT = 16 * mm
RIGHT = PAGE_W - 16 * mm
WIDTH = RIGHT - LEFT
BLACK = (0, 0, 0)

# 【基準値】原案の組版指示と、8/21の合格条件から取っている。
# ここを緩めるときは、なぜ緩めてよいかを必ず書き残すこと。
MIN_PT = 10.5           # 本文の最小サイズ。標準FAXで線が途切れない下限
MIN_URL_PT = 18.0       # URLは手入力される。ここだけは大きく保つ
MIN_BOTTOM_MM = 15.0    # FAX機が印字できない下端から逃がすための余白

_drawn = []             # 検査用に、描いた文字をすべて記録する


def register_fonts() -> str:
    """使えるフォントを探して登録し、どれを使ったかを返す。

    環境変数 DAIDA_FAX_FONT_REGULAR / DAIDA_FAX_FONT_BOLD を指定すると、
    そちらを優先する。Windows以外での検証用の逃げ道であり、
    **配布するPDFは必ずMeiryoのあるWindowsで生成すること**。
    """
    env_reg = os.environ.get("DAIDA_FAX_FONT_REGULAR")
    env_bold = os.environ.get("DAIDA_FAX_FONT_BOLD")
    candidates = list(FONT_CANDIDATES)
    if env_reg and env_bold:
        candidates.insert(0, (Path(env_reg), Path(env_bold), 0, 0))
    for regular, bold, ri, bi in candidates:
        if regular.exists() and bold.exists():
            pdfmetrics.registerFont(TTFont("Meiryo", str(regular), subfontIndex=ri))
            pdfmetrics.registerFont(TTFont("Meiryo-Bold", str(bold), subfontIndex=bi))
            return regular.name
    raise RuntimeError(
        "日本語フォントが見つかりません。Windows なら meiryo.ttc / meiryob.ttc、"
        "Linux なら fonts-noto-cjk を入れてください。"
    )


def text(c, x, y, value, size=11, font="Meiryo", align="left", limit=None):
    """文字を描く。同時に、検査に必要な情報を記録する。

    limit: この文字列が収まってよい幅（pt）。省略時は左右マージン内。
    """
    if size < MIN_PT - 1e-9:
        raise AssertionError(
            f"{size}pt は最小 {MIN_PT}pt を下回ります: 「{value}」\n"
            "  標準FAXは縦解像度が横の半分しかなく、これ未満は線が途切れます。"
        )
    w = pdfmetrics.stringWidth(value, font, size)
    allowed = limit if limit is not None else WIDTH
    if w > allowed + 1e-6:
        raise AssertionError(
            f"幅が {w / mm:.1f}mm あり、許容 {allowed / mm:.1f}mm を超えます: 「{value}」"
        )
    c.setFillColorRGB(*BLACK)
    c.setFont(font, size)
    if align == "center":
        c.drawCentredString(x, y, value)
    elif align == "right":
        c.drawRightString(x, y, value)
    else:
        c.drawString(x, y, value)
    _drawn.append((y, size, value))


def line(c, x1, y1, x2, y2, width=1.0):
    c.setStrokeColorRGB(*BLACK)
    c.setLineWidth(width)
    c.line(x1, y1, x2, y2)


def rect(c, x, y, w, h, width=1.0):
    c.setStrokeColorRGB(*BLACK)
    c.setLineWidth(width)
    c.rect(x, y, w, h, stroke=1, fill=0)


def draw_pdf() -> str:
    used_font = register_fonts()
    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    c = canvas.Canvas(str(OUTPUT), pagesize=A4, pageCompression=1)
    c.setTitle("DAIDA+ FAXチラシ")
    c.setAuthor("オレンジトア（DAIDA+運営）")

    # ------------------------------------------------------------------
    # ① 対象とメイン訴求
    # ------------------------------------------------------------------
    line(c, LEFT, 285.0 * mm, RIGHT, 285.0 * mm, 1.5)
    text(c, LEFT, 279.0 * mm, "小売店・飲食店の人事・総務ご担当者様へ", 11.5, "Meiryo-Bold")
    line(c, LEFT, 275.5 * mm, RIGHT, 275.5 * mm, 1.5)

    text(c, PAGE_W / 2, 265.5 * mm, "DAIDA+｜社内限定・代理出勤募集アプリ", 14, "Meiryo-Bold", "center")
    text(c, PAGE_W / 2, 254.5 * mm, "一人ずつ電話する代理探しから、", 24, "Meiryo-Bold", "center")
    text(c, PAGE_W / 2, 243.5 * mm, "登録スタッフへの一斉募集へ。", 26, "Meiryo-Bold", "center")
    text(c, PAGE_W / 2, 233.5 * mm, "インストール不要。インターネットから利用できます。", 12.5, "Meiryo-Bold", "center")

    # ------------------------------------------------------------------
    # ② Before / After
    # ------------------------------------------------------------------
    line(c, LEFT, 225.0 * mm, RIGHT, 225.0 * mm, 1.25)
    text(c, LEFT, 217.5 * mm, "これまで", 12, "Meiryo-Bold")
    # 【2026-08-27】「欠勤のたびに」→「急な欠勤やシフト変更のたびに」。
    # 欠勤だけに絞ると、**代理を探す場面の半分しか拾えない。**
    # 予定変更で代われる人を探すのも、まったく同じ手間になる。
    # 文言はLP（index.html のヒーロー・お困りごと）と同じにする。
    # ⚠️ 紙ごとに言い回しを変えないこと。
    text(c, LEFT + 31 * mm, 217.5 * mm, "急な欠勤やシフト変更のたびに、一人ずつ電話・調整", 12)
    text(c, LEFT, 209.5 * mm, "DAIDA+", 12, "Meiryo-Bold")
    text(c, LEFT + 31 * mm, 209.5 * mm, "勤務日時を入力し、登録スタッフへ一斉通知", 12)

    # ------------------------------------------------------------------
    # ③ 先着で確定（このサービス唯一の仕組み。太枠で独立させる）
    #
    #   改訂前は「メリット①②」の箇条書きに埋もれていた。①はメインコピーの
    #   繰り返しだったため削り、②だけを枠に入れて残した。
    #   「一斉に送る」だけなら他にもある。「最初に応募した人で自動的に決まる」
    #   ことが、店長の選ぶ手間と、選ばれなかった人への気まずさを同時に消す。
    # ------------------------------------------------------------------
    bx, by, bw, bh = LEFT, 186.0 * mm, WIDTH, 17.0 * mm
    rect(c, bx, by, bw, bh, 1.6)
    text(c, PAGE_W / 2, 196.0 * mm, "対応できるスタッフが応募。先着で確定。", 18, "Meiryo-Bold", "center")
    text(c, PAGE_W / 2, 189.5 * mm, "最初に応募したスタッフが、そのまま代理として確定します。", 11, "Meiryo", "center")

    # ------------------------------------------------------------------
    # ④ 安心の3点
    # ------------------------------------------------------------------
    text(c, LEFT, 176.5 * mm, "安心して使える3つの理由", 13.5, "Meiryo-Bold")
    thirds = [LEFT + WIDTH / 6, LEFT + WIDTH / 2, LEFT + WIDTH * 5 / 6]
    assurance = [
        ("社内限定", "登録スタッフのみ"),
        ("個人連絡先不要", "電話・個人SNSの交換不要"),
        ("スタッフ利用料0円", "受信・応募0円"),
    ]
    for cx, (heading, note) in zip(thirds, assurance):
        text(c, cx, 168.0 * mm, heading, 12, "Meiryo-Bold", "center", limit=WIDTH / 3)
        text(c, cx, 162.0 * mm, note, 10.5, "Meiryo", "center", limit=WIDTH / 3)

    # ------------------------------------------------------------------
    # ⑤ 料金
    #
    #   【重要】キャンペーンの期限を必ず入れる。紙は回収できない。
    #   期限の無い「3か月無料」は、11月に読まれた瞬間に事実と違う表示になる。
    #   同時に、日付が入って初めて「いま動く理由」になる。制約ではなく武器。
    # ------------------------------------------------------------------
    line(c, LEFT, 154.0 * mm, RIGHT, 154.0 * mm, 1.0)
    # 【枠の中は「申し出」だけにする（2026-08-26）】
    #
    # 一度、枠の中に条件（有料プランへの加入が必要）まで入れた。
    # 枠が「お得です」と「ただし有料です」の2つを同時に言う形になり、読みにくかった。
    # さらに、その下の「有料プラン（税込）」は料金表の見出しなのに、
    # そこへ注意書きをくっつけてしまい、1行が2つの役目を持っていた。
    #
    # → **枠の中は申し出だけ。条件は枠のすぐ下に、※で並べる。**
    #
    # ⚠️ ただし「すぐ下」を守ること。条件を離した場所に置いてはいけない。
    # 2026-08-25、貼り紙で「0円」と条件を離して書き、
    # 「下を見ると分かるが、わかりにくい」と指摘された（L-033）。
    # 枠と条件の間には、何も挟まないこと。
    fx, fy, fw, fh = LEFT, 139.0 * mm, WIDTH, 9.5 * mm
    rect(c, fx, fy, fw, fh, 1.6)
    # 「お申し込み」ではなく「ご登録」と書く。利用規約・特定商取引法に基づく表記が
    # どちらも「初回登録した店舗」を条件にしており、問い合わせではなく登録が基準のため。
    text(c, PAGE_W / 2, 142.0 * mm, "2026年10月31日までのご登録で 3か月無料", 16, "Meiryo-Bold", "center", limit=fw - 8 * mm)

    # 【2026-08-26 修正】以前は「無料期間終了後も、代理募集は月2回まで0円」だった。
    # 無料枠そのものが廃止され、**事実と違う表示**になっていた。
    # 文言はLP（index.html）・利用規約と一字一句そろえる。
    # ⚠️ 紙ごとに言い回しを変えないこと。それ自体が問い合わせの元になる。
    text(c, LEFT, 133.5 * mm, "※無料期間終了後に代理募集を利用するには、有料プランへの加入が必要です。", 10.5)
    text(c, LEFT, 128.0 * mm, "※無料期間終了後、自動的に有料プランへ移行することはありません。", 10.5)
    text(c, LEFT, 122.5 * mm, "※同じメールアドレスで2店舗目以降を登録される場合、無料期間は適用されません。", 10.5)

    text(c, LEFT, 117.0 * mm, "有料プラン（税込）", 11, "Meiryo-Bold")
    px, py, pw, ph = LEFT, 100.0 * mm, WIDTH, 14.7 * mm
    pcol = pw / 3
    rect(c, px, py, pw, ph, 1.25)
    for i in (1, 2):
        line(c, px + pcol * i, py, px + pcol * i, py + ph, 1.0)
    plans = [("1か月", "980円（税込）"), ("3か月", "2,352円（税込）"), ("12か月", "5,880円（税込）")]
    for i, (period, price) in enumerate(plans):
        cx = px + pcol * (i + 0.5)
        text(c, cx, py + 10.95 * mm, period, 11, "Meiryo-Bold", "center", limit=pcol)
        text(c, cx, py + 2.95 * mm, price, 14, "Meiryo-Bold", "center", limit=pcol)

    # ------------------------------------------------------------------
    # ⑥ 他社比較
    # ------------------------------------------------------------------
    text(c, LEFT, 93.5 * mm, "スタッフ35名・1店舗・1か月プランで利用した場合の比較例", 13.5, "Meiryo-Bold")
    tx, ty, tw, th = LEFT, 67.0 * mm, WIDTH, 22 * mm
    widths = [38 * mm, (tw - 38 * mm) / 3, (tw - 38 * mm) / 3, (tw - 38 * mm) / 3]
    row_h = th / 3
    rect(c, tx, ty, tw, th, 1.25)
    xx = tx
    for w in widths[:-1]:
        xx += w
        line(c, xx, ty, xx, ty + th, 1.0)
    for i in (1, 2):
        line(c, tx, ty + row_h * i, tx + tw, ty + row_h * i, 1.0)
    centers = []
    pos = tx
    for w in widths:
        centers.append(pos + w / 2)
        pos += w
    col_w = (tw - 38 * mm) / 3
    text(c, centers[1], ty + 17.0 * mm, "DAIDA+", 11, "Meiryo-Bold", "center", limit=col_w)
    text(c, centers[2], ty + 17.0 * mm, "A社", 10.5, "Meiryo-Bold", "center", limit=col_w)
    text(c, centers[3], ty + 17.0 * mm, "B社", 10.5, "Meiryo-Bold", "center", limit=col_w)
    text(c, tx + 9.5 * mm, ty + 10.0 * mm, "月額コスト", 10.5, "Meiryo-Bold", limit=38 * mm - 12 * mm)
    text(c, centers[1], ty + 9.0 * mm, "980円（税込）", 10.5, "Meiryo-Bold", "center", limit=col_w)
    text(c, centers[2], ty + 9.0 * mm, "15,750円", 10.5, "Meiryo", "center", limit=col_w)
    text(c, centers[3], ty + 9.0 * mm, "11,550円", 10.5, "Meiryo", "center", limit=col_w)
    text(c, tx + 8.0 * mm, ty + 2.7 * mm, "料金システム", 10.5, "Meiryo-Bold", limit=38 * mm - 10 * mm)
    text(c, centers[1], ty + 2.0 * mm, "1店舗ごとの定額", 10.5, "Meiryo-Bold", "center", limit=col_w)
    text(c, centers[2], ty + 2.0 * mm, "1ユーザー課金", 10.5, "Meiryo", "center", limit=col_w)
    text(c, centers[3], ty + 2.0 * mm, "1ユーザー課金", 10.5, "Meiryo", "center", limit=col_w)

    # 改訂前は2行に割れており、2行目が「※」なしで始まるため注記か本文か迷った。
    text(c, LEFT, 60.5 * mm, "※2026年8月時点の公開情報にもとづく参考例です。料金・サービス内容は変更される場合があります。", 10.5)

    # ------------------------------------------------------------------
    # ⑦ CTA・送信元・配信停止
    #
    #   配信停止文は確定文言のため、語句は一字も変えない。
    #   ただし1行では左右マージンに収まらないため、改行位置だけで2行に分ける。
    # ------------------------------------------------------------------
    line(c, LEFT, 54.0 * mm, RIGHT, 54.0 * mm, 1.5)
    # 期限は料金枠にも書いてあるが、CTAでもう一度出す。
    # 「あとで見よう」と思った瞬間に紙は引き出しへ入る。動く理由は、動く場所に置く。
    text(c, PAGE_W / 2, 47.0 * mm, "10月31日まで3か月無料｜料金・導入方法は公式サイトへ", 13, "Meiryo-Bold", "center")
    ux, uy, uw, uh = LEFT + 18 * mm, 33.0 * mm, WIDTH - 36 * mm, 10.0 * mm
    rect(c, ux, uy, uw, uh, 1.5)
    # 【2026-08-30】FAX経由の登録を数えられるようにするため、専用ページ(/fax)へ変更。
    # ⚠️ ここを直したら、着地先の daida-plus-lp/fax/index.html も必ず同じ工程で
    # 用意されていること（L-038：URLだけ変えて配る紙が置き去りにならないように）。
    text(c, PAGE_W / 2, uy + 2.6 * mm, "https://daida-store.jp/fax", 18.5, "Meiryo-Bold", "center", limit=uw - 6 * mm)

    text(c, LEFT, 26.0 * mm, "送信元：オレンジトア（DAIDA+運営）", 10.5)
    text(c, LEFT, 20.5 * mm, "FAX配信停止をご希望の場合は、お手数ですが、", 10.5)
    text(c, LEFT, 15.5 * mm, "公式サイトのお問い合わせフォームよりお申し付けください。", 10.5)

    c.showPage()
    c.save()
    return used_font


def assert_layout() -> None:
    """描き終えた内容が基準を満たしているかを検査する。"""
    lowest = min(y for y, _, _ in _drawn)
    if lowest < MIN_BOTTOM_MM * mm - 1e-6:
        raise AssertionError(
            f"最下段の文字が下端から {lowest / mm:.1f}mm しかありません"
            f"（基準 {MIN_BOTTOM_MM}mm 以上）。\n"
            "  多くのFAX機は用紙下端5mm前後を印字しません。"
            "ここが切れると、配信停止の案内が受信側に届きません。"
        )
    urls = [(y, s, v) for y, s, v in _drawn if v.startswith("http")]
    if not urls:
        raise AssertionError("URLが1つも描かれていません。")
    for _, size, value in urls:
        if size < MIN_URL_PT - 1e-9:
            raise AssertionError(f"URLが {size}pt です（基準 {MIN_URL_PT}pt 以上）: {value}")
    smallest = min(s for _, s, _ in _drawn)
    print(f"  検査OK 最小文字 {smallest}pt / 最下段 {lowest / mm:.1f}mm / 文字要素 {len(_drawn)}件")
    print(f"  可視文字数 {sum(len(v) for _, _, v in _drawn)}字")


if __name__ == "__main__":
    font = draw_pdf()
    assert_layout()
    print(f"  使用フォント {font}")
    print(OUTPUT)
