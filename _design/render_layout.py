"""横屏 v2 版式离屏渲染：取景高度撑满 + 拖拽条在最右边。

与 Sources/Landscape/LandscapeLayout.swift 使用同一套约束，改动必须同步。
"""
from PIL import Image, ImageDraw, ImageFont, ImageFilter

S = 2
W, H = 956, 440
INSET_L, INSET_R, INSET_B, INSET_T = 59, 59, 21, 0

MARGIN = 8
ASPECT = 4224 / 3024

KNOB, KNOB_GAP = 56, 8
LENS, LENS_GAP = 44, 8
BAR_W = 52
LGAP = 6
REC = 56
GEAR = 38
GAP = 12

# ---------- 解算 ----------
# 1) 左侧先给焦距切换留整列
LENS_COL = (INSET_L + MARGIN, (H - (LENS * 4 + LENS_GAP * 3)) / 2, LENS, LENS * 4 + LENS_GAP * 3)
GEAR_BOX = (LENS_COL[0], H - INSET_B - MARGIN - GEAR, GEAR, GEAR)

# 2) 取景从焦距列右侧开始，高度撑满
PREVIEW_X = LENS_COL[0] + LENS + LGAP
PREVIEW_H = float(H)
PREVIEW_W = PREVIEW_H * ASPECT
max_preview_w = W * 0.78
if PREVIEW_W > max_preview_w:
    PREVIEW_W = max_preview_w
    PREVIEW_H = PREVIEW_W / ASPECT
PREVIEW = (PREVIEW_X, 0.0, PREVIEW_W, PREVIEW_H)

# 3) 竖条贴最右，参数列贴条左侧
rail_x = W - INSET_R - MARGIN - BAR_W
BAR = (rail_x, INSET_T + MARGIN, BAR_W, H - INSET_B - 2 * MARGIN)
knob_x = rail_x - GAP - KNOB
KNOB_COL = (knob_x, (H - (KNOB * 6 + KNOB_GAP * 5)) / 2, KNOB, KNOB * 6 + KNOB_GAP * 5)

# 4) 录制键只能浮在画面右下角
REC_BOX = (PREVIEW_X + PREVIEW_W - 2 * MARGIN - REC,
           H - INSET_B - MARGIN - REC, REC, REC)
CHIPS = (PREVIEW_X + 10, INSET_T + 10)

YELLOW = (255, 206, 40, 232)
YELLOW_RING = (255, 232, 140, 200)
DARK = (30, 22, 0, 255)
WHITE = (255, 255, 255, 255)
DIM = (255, 255, 255, 150)


def px(v):
    return int(round(v * S))


def font(size, bold=False):
    return ImageFont.truetype("C:/Windows/Fonts/msyhbd.ttc" if bold else "C:/Windows/Fonts/msyh.ttc", px(size))


F_KNOB = font(14, True)
F_VAL = font(8.5)
F_CAP = font(7)
F_LENS = font(11, True)
F_CHIP = font(9.5)
F_NAME = font(9)
F_NUM = font(10)

img = Image.new("RGB", (W * S, H * S), (6, 6, 8))
d = ImageDraw.Draw(img, "RGBA")


def glass_circle(cx, cy, r, tint=None, ring=None, sh=80):
    box = [px(cx - r), px(cy - r), px(cx + r), px(cy + r)]
    layer = Image.new("RGBA", img.size, (0, 0, 0, 0))
    ImageDraw.Draw(layer).ellipse([box[0], box[1] + px(2), box[2], box[3] + px(4)], fill=(0, 0, 0, sh))
    img.paste(layer.filter(ImageFilter.GaussianBlur(px(3))), (0, 0), layer)
    dd = ImageDraw.Draw(img, "RGBA")
    dd.ellipse(box, fill=tint if tint else (255, 255, 255, 38))
    dd.arc(box, 195, 345, fill=(255, 255, 255, 165 if tint else 120), width=px(1))
    dd.ellipse(box, outline=ring if ring else (255, 255, 255, 105), width=px(1))


def glass_round(x, y, w, h, r, tint=None, ring=None, sh=80):
    box = [px(x), px(y), px(x + w), px(y + h)]
    layer = Image.new("RGBA", img.size, (0, 0, 0, 0))
    ImageDraw.Draw(layer).rounded_rectangle([box[0], box[1] + px(2), box[2], box[3] + px(4)],
                                            radius=px(r), fill=(0, 0, 0, sh))
    img.paste(layer.filter(ImageFilter.GaussianBlur(px(3))), (0, 0), layer)
    dd = ImageDraw.Draw(img, "RGBA")
    dd.rounded_rectangle(box, radius=px(r), fill=tint if tint else (255, 255, 255, 34))
    dd.rounded_rectangle(box, radius=px(r), outline=ring if ring else (255, 255, 255, 100), width=px(1))


def text_at(x, y, s, fnt, fill):
    d.text((px(x), px(y)), s, font=fnt, fill=fill, anchor="mm")


# ---------- 取景：撑满高度 ----------
pw, ph = px(PREVIEW_W), px(PREVIEW_H)
frame = Image.new("RGB", (pw, ph))
fd = ImageDraw.Draw(frame)
for y in range(ph):
    t = y / ph
    fd.line([(0, y), (pw, y)], fill=(int(30 + 22 * (1 - t)), int(37 + 28 * (1 - t)), int(47 + 36 * (1 - t))))
glow = Image.new("RGBA", (pw, ph), (0, 0, 0, 0))
gd = ImageDraw.Draw(glow)
cx, cy, rad = pw * 0.60, ph * 0.38, pw * 0.42
for i in range(30, 0, -1):
    rr = rad * i / 30
    gd.ellipse([cx - rr, cy - rr * 0.8, cx + rr, cy + rr * 0.8], fill=(255, 212, 138, int(1.7 * i)))
frame.paste(glow, (0, 0), glow)
fd = ImageDraw.Draw(frame, "RGBA")
for i in (1, 2):
    fd.line([(pw * i / 3, 0), (pw * i / 3, ph)], fill=(255, 255, 255, 26), width=S)
    fd.line([(0, ph * i / 3), (pw, ph * i / 3)], fill=(255, 255, 255, 26), width=S)
img.paste(frame, (px(PREVIEW_X), 0))
d = ImageDraw.Draw(img, "RGBA")

# ---------- 左轨：焦距（浮在画面左侧） ----------
ly = LENS_COL[1]
for label, on in [("0.5×", False), ("1×", True), ("4×", False), ("8×", False)]:
    cyc, cxc = ly + LENS / 2, LENS_COL[0] + LENS / 2
    if on:
        glass_circle(cxc, cyc, LENS / 2, tint=(255, 255, 255, 120), ring=(255, 255, 255, 215), sh=95)
        fg = WHITE
    else:
        glass_circle(cxc, cyc, LENS / 2, tint=(255, 255, 255, 16), ring=(255, 255, 255, 66), sh=55)
        fg = DIM
    text_at(cxc, cyc, label, F_LENS, fg)
    ly += LENS + LENS_GAP

# ---------- 右轨：参数列 ----------
params = [("1/48", "AUTO", "快门", "auto"), ("640", "ISO", "", "manual"),
          ("0.42", "手动", "焦距", "sel"), ("+0.3", "AUTO", "曝光", "auto"),
          ("5600", "AUTO", "白平衡", "auto"), ("A", "自动", "", "all")]
ky = KNOB_COL[1]
for k, v, cap, state in params:
    cyk, cxk = ky + KNOB / 2, KNOB_COL[0] + KNOB / 2
    if state == "auto":
        glass_circle(cxk, cyk, KNOB / 2, tint=YELLOW, ring=YELLOW_RING, sh=100); fg = DARK
    elif state == "sel":
        glass_circle(cxk, cyk, KNOB / 2, tint=(255, 255, 255, 96), ring=(255, 255, 255, 225), sh=105); fg = WHITE
    elif state == "all":
        glass_circle(cxk, cyk, KNOB / 2, tint=(255, 255, 255, 54), ring=(255, 255, 255, 150), sh=85); fg = WHITE
    else:
        glass_circle(cxk, cyk, KNOB / 2, tint=(255, 255, 255, 20), ring=(255, 255, 255, 82), sh=60); fg = WHITE
    if state == "all":
        text_at(cxk, cyk - 5, "A", F_KNOB, fg)
        text_at(cxk, cyk + 11, "自动", F_CAP, fg)
    else:
        text_at(cxk, cyk - 8, k, F_KNOB, fg)
        text_at(cxk, cyk + 4, v, F_VAL, fg if state != "manual" else (255, 255, 255, 205))
        if cap:
            text_at(cxk, cyk + 15, cap, F_CAP, fg if state != "manual" else (255, 255, 255, 135))
    ky += KNOB + KNOB_GAP

# ---------- 最右：唯一一条拖拽条（竖向） ----------
bx, by, bw, bh = BAR
glass_round(bx, by, bw, bh, bw / 2, tint=(255, 255, 255, 26), ring=(255, 255, 255, 88), sh=90)
text_at(bx + bw / 2, by + 26, "焦距", F_NAME, (255, 255, 255, 165))
tx = bx + bw / 2
ty0, ty1 = by + 34, by + bh - 34
d.rounded_rectangle([px(tx - 3), px(ty0), px(tx + 3), px(ty1)], radius=px(3), fill=(255, 255, 255, 46))
fy = ty1 - (ty1 - ty0) * 0.58
d.rounded_rectangle([px(tx - 3), px(fy), px(tx + 3), px(ty1)], radius=px(3), fill=(255, 255, 255, 200))
glass_circle(tx, fy, 11, tint=(255, 255, 255, 245), ring=(255, 255, 255, 255), sh=95)
text_at(tx, by + bh - 20, "0.42", F_NUM, WHITE)

# ---------- 录制键 / 设置 ----------
gx, gy, gw, gh = GEAR_BOX
glass_circle(gx + gw / 2, gy + gh / 2, gw / 2, tint=(255, 255, 255, 26), ring=(255, 255, 255, 110), sh=55)
text_at(gx + gw / 2, gy + gh / 2, "⚙", font(14), (255, 255, 255, 235))

rx, ry, rw, rh = REC_BOX
glass_circle(rx + rw / 2, ry + rh / 2, rw / 2, tint=(255, 255, 255, 10), ring=(255, 255, 255, 90), sh=60)
d.ellipse([px(rx + rw / 2 - 11), px(ry + rh / 2 - 11), px(rx + rw / 2 + 11), px(ry + rh / 2 + 11)], fill=(255, 59, 48))

# ---------- 顶部信息：压在画面左上角 ----------
cx_chip, cy_chip = CHIPS
for label, fg in [("● 00:00:07", (255, 96, 84)), ("剩 1:12", WHITE)]:
    wch = d.textlength(label, font=F_CHIP) / S + 18
    glass_round(cx_chip, cy_chip, wch, 23, 11.5, tint=(255, 255, 255, 26), ring=(255, 255, 255, 70), sh=45)
    text_at(cx_chip + wch / 2, cy_chip + 11.5, label, F_CHIP, fg)
    cx_chip += wch + 8

img.save("F:/OpenGate/_design/landscape.png", "PNG")
print("saved", img.size)

# ---------- 自检 ----------
boxes = {"preview": PREVIEW, "lens": LENS_COL, "knobs": KNOB_COL,
         "bar": BAR, "rec": REC_BOX, "gear": GEAR_BOX}
print("\n--- 解出的矩形 ---")
for n, (x, y, w, h) in boxes.items():
    print(f"{n:8s} x {x:>6.1f}..{x + w:>6.1f}  y {y:>6.1f}..{y + h:>6.1f}  ({w:.1f}×{h:.1f})")

ok = True
print("\n--- 检查 ---")
names = list(boxes)
for i in range(len(names)):
    for j in range(i + 1, len(names)):
        a, b = boxes[names[i]], boxes[names[j]]
        hit = not (a[0] + a[2] <= b[0] or b[0] + b[2] <= a[0] or a[1] + a[3] <= b[1] or b[1] + b[3] <= a[1])
        intentional = {names[i], names[j]} in ({"preview", "rec"},)
        if hit and not intentional:
            ok = False
        tag = "重叠（设计如此）" if hit and intentional else ("重叠 ✗" if hit else "不重叠 ✓")
        print(f"{names[i]:8s} × {names[j]:8s}: {tag}")

for n, (x, y, w, h) in boxes.items():
    inside = (x >= -0.5 and x + w <= W - INSET_R + 0.5
              and y >= -0.5 and y + h <= H - INSET_B + 0.5)
    if n == "preview":
        inside = abs(h - H) < 0.5
    ok &= inside
    label = "高度撑满 ✓" if n == "preview" and inside else ("在安全区内 ✓" if inside else "越界 ✗")
    print(f"{n:8s} {label}")

print("\n版式自检:", "通过" if ok else "未通过")
