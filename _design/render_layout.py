"""按与 SwiftUI 完全相同的点位，把横屏版式离屏渲染出来做检查。

这不是示意图：要写进 LandscapeScreen.swift 的那组数字（x/y/w/h、间距、字号）
在这里用同一套约束算出来再落成像素，用来在推构建之前确认不重叠、不出安全区。
"""
from PIL import Image, ImageDraw, ImageFont, ImageFilter

S = 2                                     # 2× 渲染
W, H = 956, 440                           # iPhone 17 Pro Max 横屏逻辑尺寸
INSET_L, INSET_R, INSET_B = 59, 59, 21    # 横屏安全区实测值

MARGIN = 8
RAIL_W, KNOB, KNOB_GAP = 56, 56, 8
LENS_W, LENS, LENS_GAP = 44, 44, 8
BAR_H, REC, TRACK_GAP = 52, 52, 16
ASPECT = 4224 / 3024                      # Open Gate 画幅 1.397

YELLOW = (255, 206, 40, 232)
YELLOW_RING = (255, 232, 140, 200)
DARK = (30, 22, 0, 255)
WHITE = (255, 255, 255, 255)
DIM = (255, 255, 255, 150)


# ---------- 版式计算（与 SwiftUI 同一套约束） ----------
LEFT = INSET_L + MARGIN
RIGHT = W - INSET_R - MARGIN
RAIL_X = RIGHT - RAIL_W
RAIL_Y = 32
COLUMN_H = KNOB * 6 + KNOB_GAP * 5

TOP = 8
BOTTOM_LIMIT = H - INSET_B - MARGIN
BAR_Y = BOTTOM_LIMIT - BAR_H
PREVIEW_MAX_H = BAR_Y - MARGIN - TOP
PREVIEW_H = PREVIEW_MAX_H
PREVIEW_W = PREVIEW_H * ASPECT
GROUP_W = LENS_W + 12 + PREVIEW_W
FREE_W = (RAIL_X - 12) - LEFT
GROUP_X = LEFT + (FREE_W - GROUP_W) / 2
LENS_X = GROUP_X
LENS_Y = TOP + (PREVIEW_H - (LENS * 4 + LENS_GAP * 3)) / 2
PREVIEW_X = GROUP_X + LENS_W + 12
BAR_X = PREVIEW_X
BAR_W = PREVIEW_W
TRACK_X = BAR_X + REC + TRACK_GAP
TRACK_W = BAR_W - REC - TRACK_GAP


def px(v):
    return int(round(v * S))


def font(size, bold=False):
    path = "C:/Windows/Fonts/msyhbd.ttc" if bold else "C:/Windows/Fonts/msyh.ttc"
    return ImageFont.truetype(path, px(size))


F_KNOB = font(14, True)
F_VAL = font(8.5)
F_CAP = font(7)
F_LENS = font(11, True)
F_CHIP = font(9.5)
F_NAME = font(10)
F_NUM = font(11)

img = Image.new("RGB", (W * S, H * S), (8, 8, 10))   # RGB 底，alpha 才会真正混合
d = ImageDraw.Draw(img, "RGBA")


def soft_shadow(draw_fn, blur=3, alpha=0):
    layer = Image.new("RGBA", img.size, (0, 0, 0, 0))
    draw_fn(ImageDraw.Draw(layer))
    img.paste(layer.filter(ImageFilter.GaussianBlur(px(blur))), (0, 0), layer)


def glass_circle(cx, cy, r, tint=None, ring=None, sh=80):
    box = [px(cx - r), px(cy - r), px(cx + r), px(cy + r)]
    soft_shadow(lambda ld: ld.ellipse([box[0], box[1] + px(2), box[2], box[3] + px(4)],
                                      fill=(0, 0, 0, sh)))
    dd = ImageDraw.Draw(img, "RGBA")
    dd.ellipse(box, fill=tint if tint else (255, 255, 255, 38))
    dd.arc(box, 195, 345, fill=(255, 255, 255, 165 if tint else 120), width=px(1))
    dd.ellipse(box, outline=ring if ring else (255, 255, 255, 105), width=px(1))


def glass_round(x, y, w, h, r, tint=None, ring=None, sh=80):
    box = [px(x), px(y), px(x + w), px(y + h)]
    soft_shadow(lambda ld: ld.rounded_rectangle(
        [box[0], box[1] + px(2), box[2], box[3] + px(4)], radius=px(r), fill=(0, 0, 0, sh)))
    dd = ImageDraw.Draw(img, "RGBA")
    dd.rounded_rectangle(box, radius=px(r), fill=tint if tint else (255, 255, 255, 34))
    dd.arc([box[0], box[1], box[2], box[1] + px(r * 2)], 195, 345,
           fill=(255, 255, 255, 130), width=px(1))
    dd.rounded_rectangle(box, radius=px(r), outline=ring if ring else (255, 255, 255, 100),
                         width=px(1))


def text_at(x, y, s, fnt, fill):
    d.text((px(x), px(y)), s, font=fnt, fill=fill, anchor="mm")


def fit(s, fnt, maxw):
    if d.textlength(s, font=fnt) <= px(maxw):
        return s
    while s and d.textlength(s + "…", font=fnt) > px(maxw):
        s = s[:-1]
    return s + "…"


# ---------- 取景画面 ----------
pw, ph = px(PREVIEW_W), px(PREVIEW_H)
frame = Image.new("RGB", (pw, ph))
fd = ImageDraw.Draw(frame)
for y in range(ph):
    t = y / ph
    fd.line([(0, y), (pw, y)], fill=(int(30 + 22 * (1 - t)),
                                    int(37 + 28 * (1 - t)),
                                    int(47 + 36 * (1 - t))))
glow = Image.new("RGBA", (pw, ph), (0, 0, 0, 0))
gd = ImageDraw.Draw(glow)
cx, cy, rad = pw * 0.62, ph * 0.36, pw * 0.42
for i in range(30, 0, -1):
    rr = rad * i / 30
    gd.ellipse([cx - rr, cy - rr * 0.78, cx + rr, cy + rr * 0.78],
               fill=(255, 212, 138, int(1.7 * i)))
frame.paste(glow, (0, 0), glow)
fd = ImageDraw.Draw(frame, "RGBA")
for i in (1, 2):
    fd.line([(pw * i / 3, 0), (pw * i / 3, ph)], fill=(255, 255, 255, 26), width=S)
    fd.line([(0, ph * i / 3), (pw, ph * i / 3)], fill=(255, 255, 255, 26), width=S)
img.paste(frame, (px(PREVIEW_X), px(TOP)))
d = ImageDraw.Draw(img, "RGBA")

# ---------- 左侧焦距切换 ----------
lenses = [("0.5×", False), ("1×", True), ("4×", False), ("8×", False)]
ly = LENS_Y
for label, on in lenses:
    cyc = ly + LENS / 2
    cxc = LENS_X + LENS / 2
    if on:
        glass_circle(cxc, cyc, LENS / 2, tint=(255, 255, 255, 120),
                     ring=(255, 255, 255, 215), sh=95)
        fg = WHITE
    else:
        glass_circle(cxc, cyc, LENS / 2, tint=(255, 255, 255, 16),
                     ring=(255, 255, 255, 66), sh=55)
        fg = DIM
    text_at(cxc, cyc, label, F_LENS, fg)
    ly += LENS + LENS_GAP

# ---------- 右侧参数列 ----------
params = [
    ("1/48", "AUTO", "快门", "auto"),
    ("640", "ISO", "", "manual"),
    ("0.42", "手动", "焦距", "sel"),
    ("+0.3", "AUTO", "曝光", "auto"),
    ("5600", "AUTO", "白平衡", "auto"),
    ("A", "全部自动", "", "all"),
]
ky = RAIL_Y
for k, v, cap, state in params:
    cyk = ky + KNOB / 2
    cxk = RAIL_X + RAIL_W / 2
    if state == "auto":
        glass_circle(cxk, cyk, KNOB / 2, tint=YELLOW, ring=YELLOW_RING, sh=100)
        fg = DARK
    elif state == "sel":
        glass_circle(cxk, cyk, KNOB / 2, tint=(255, 255, 255, 112),
                     ring=(255, 255, 255, 225), sh=105)
        fg = WHITE
    elif state == "all":
        glass_circle(cxk, cyk, KNOB / 2, tint=(255, 255, 255, 54),
                     ring=(255, 255, 255, 150), sh=85)
        fg = WHITE
    else:
        glass_circle(cxk, cyk, KNOB / 2, tint=(255, 255, 255, 20),
                     ring=(255, 255, 255, 82), sh=60)
        fg = WHITE

    if state == "all":
        text_at(cxk, cyk - 5, "A", F_KNOB, fg)
        text_at(cxk, cyk + 11, "全部自动", F_CAP, fg)
    else:
        text_at(cxk, cyk - 8, fit(k, F_KNOB, KNOB - 10), F_KNOB, fg)
        text_at(cxk, cyk + 4, fit(v, F_VAL, KNOB - 8), F_VAL,
                fg if state != "manual" else (255, 255, 255, 205))
        if cap:
            text_at(cxk, cyk + 15, cap, F_CAP,
                    fg if state != "manual" else (255, 255, 255, 135))
    ky += KNOB + KNOB_GAP

# ---------- 顶部信息 ----------
chips = [("● 00:00:07", (255, 96, 84)), ("ProRes RAW · 24fps", WHITE), ("剩 1:12", WHITE)]
cx_chip = BAR_X
for label, fg in chips:
    wch = d.textlength(label, font=F_CHIP) / S + 18
    glass_round(cx_chip, 10, wch, 23, 11.5, tint=(255, 255, 255, 26),
                ring=(255, 255, 255, 70), sh=45)
    text_at(cx_chip + wch / 2, 21.5, label, F_CHIP, fg)
    cx_chip += wch + 8

# ---------- 设置（画面左侧空白处） ----------
gear_x = LENS_X - 28
gear_y = TOP + 19
glass_circle(gear_x, gear_y, 19, tint=(255, 255, 255, 26), ring=(255, 255, 255, 110), sh=60)
text_at(gear_x, gear_y, "⚙", font(15), (255, 255, 255, 235))

# ---------- 底部：录制 + 唯一一条拖拽条 ----------
glass_circle(BAR_X + REC / 2, BAR_Y + REC / 2, REC / 2,
             tint=(255, 255, 255, 36), ring=(255, 255, 255, 120), sh=95)
d.ellipse([px(BAR_X + REC / 2 - 10), px(BAR_Y + REC / 2 - 10),
           px(BAR_X + REC / 2 + 10), px(BAR_Y + REC / 2 + 10)], fill=(255, 59, 48))

glass_round(TRACK_X, BAR_Y, TRACK_W, BAR_H, BAR_H / 2,
            tint=(255, 255, 255, 28), ring=(255, 255, 255, 88), sh=85)
text_at(TRACK_X + 26, BAR_Y + BAR_H / 2, "焦距", F_NAME, (255, 255, 255, 150))

rail_x0 = TRACK_X + 50
rail_x1 = TRACK_X + TRACK_W - 72
rail_cy = BAR_Y + BAR_H / 2
d.rounded_rectangle([px(rail_x0), px(rail_cy - 3), px(rail_x1), px(rail_cy + 3)],
                    radius=px(3), fill=(255, 255, 255, 46))
frac = 0.58
fx = rail_x0 + (rail_x1 - rail_x0) * frac
d.rounded_rectangle([px(rail_x0), px(rail_cy - 3), px(fx), px(rail_cy + 3)],
                    radius=px(3), fill=(255, 255, 255, 200))
glass_circle(fx, rail_cy, 11, tint=(255, 255, 255, 245),
             ring=(255, 255, 255, 255), sh=95)
text_at(TRACK_X + TRACK_W - 16, rail_cy, "0.42", F_NUM, WHITE)

out = "F:/OpenGate/_design/landscape.png"
img.save(out, "PNG")
print("saved", out, img.size)

# ---------- 几何自检 ----------
boxes = {
    "preview": (PREVIEW_X, TOP, PREVIEW_W, PREVIEW_H),
    "rail": (RAIL_X, RAIL_Y, RAIL_W, COLUMN_H),
    "lenses": (LENS_X, LENS_Y, LENS_W, LENS * 4 + LENS_GAP * 3),
    "bar": (BAR_X, BAR_Y, BAR_W, BAR_H),
    "gear": (LENS_X - 28 - 19, TOP + 19 - 19, 38, 38),
}
print("\n--- 解出的矩形 ---")
for n, (x, y, w, h) in boxes.items():
    print(f"{n:8s} x {x:>6.1f}..{x + w:>6.1f}  y {y:>5.1f}..{y + h:>5.1f}  ({w:.1f}×{h:.1f})")

ok = True
print("\n--- 检查 ---")
names = list(boxes)
for i in range(len(names)):
    for j in range(i + 1, len(names)):
        a = boxes[names[i]]
        b = boxes[names[j]]
        hit = not (a[0] + a[2] <= b[0] or b[0] + b[2] <= a[0]
                   or a[1] + a[3] <= b[1] or b[1] + b[3] <= a[1])
        # 底栏与取景左对齐，允许在 y 上相接但不相交
        if hit:
            ok = False
        print(f"{names[i]:8s} × {names[j]:8s}: {'重叠 ✗' if hit else '不重叠 ✓'}")

for n, (x, y, w, h) in boxes.items():
    inside = (x >= INSET_L - .5 and x + w <= W - INSET_R + .5
              and y >= -.5 and y + h <= H - INSET_B + .5)
    ok &= inside
    print(f"{n:8s} 在安全区内: {'✓' if inside else '✗'}")

print("\n版式自检:", "通过" if ok else "未通过")
