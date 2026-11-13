"""横竖屏版式离屏渲染与几何自检。

与 Sources/Landscape/LandscapeLayout.swift、Sources/Portrait/PortraitLayout.swift
使用同一套约束，改动必须同步。产物：landscape.png / portrait.png。
无头浏览器在本沙箱里静默不出图，所以用 Pillow 按同一组数字离屏画。
"""
from PIL import Image, ImageDraw, ImageFont, ImageFilter

S = 2
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
F_TINY = font(9, True)
F_STATUS = font(8)


class Canvas:
    def __init__(self, w, h):
        self.W, self.H = w, h
        self.img = Image.new("RGB", (w * S, h * S), (6, 6, 8))
        self.d = ImageDraw.Draw(self.img, "RGBA")

    def glass_circle(self, cx, cy, r, tint=None, ring=None, sh=80):
        box = [px(cx - r), px(cy - r), px(cx + r), px(cy + r)]
        layer = Image.new("RGBA", self.img.size, (0, 0, 0, 0))
        ImageDraw.Draw(layer).ellipse([box[0], box[1] + px(2), box[2], box[3] + px(4)], fill=(0, 0, 0, sh))
        self.img.paste(layer.filter(ImageFilter.GaussianBlur(px(3))), (0, 0), layer)
        dd = ImageDraw.Draw(self.img, "RGBA")
        dd.ellipse(box, fill=tint if tint else (255, 255, 255, 38))
        dd.arc(box, 195, 345, fill=(255, 255, 255, 165 if tint else 120), width=px(1))
        dd.ellipse(box, outline=ring if ring else (255, 255, 255, 105), width=px(1))

    def glass_round(self, x, y, w, h, r, tint=None, ring=None, sh=80):
        box = [px(x), px(y), px(x + w), px(y + h)]
        layer = Image.new("RGBA", self.img.size, (0, 0, 0, 0))
        ImageDraw.Draw(layer).rounded_rectangle([box[0], box[1] + px(2), box[2], box[3] + px(4)],
                                                radius=px(r), fill=(0, 0, 0, sh))
        self.img.paste(layer.filter(ImageFilter.GaussianBlur(px(3))), (0, 0), layer)
        dd = ImageDraw.Draw(self.img, "RGBA")
        dd.rounded_rectangle(box, radius=px(r), fill=tint if tint else (255, 255, 255, 34))
        dd.rounded_rectangle(box, radius=px(r), outline=ring if ring else (255, 255, 255, 100), width=px(1))

    def text(self, x, y, s, fnt, fill):
        self.d.text((px(x), px(y)), s, font=fnt, fill=fill, anchor="mm")

    def preview(self, box):
        x, y, w, h = box
        pw, ph = px(w), px(h)
        frame = Image.new("RGB", (pw, ph))
        fd = ImageDraw.Draw(frame)
        for row in range(ph):
            t = row / ph
            fd.line([(0, row), (pw, row)],
                    fill=(int(30 + 22 * (1 - t)), int(37 + 28 * (1 - t)), int(47 + 36 * (1 - t))))
        glow = Image.new("RGBA", (pw, ph), (0, 0, 0, 0))
        gd = ImageDraw.Draw(glow)
        cx, cy, rad = pw * 0.60, ph * 0.38, min(pw, ph) * 0.42
        for i in range(30, 0, -1):
            rr = rad * i / 30
            gd.ellipse([cx - rr, cy - rr * 0.8, cx + rr, cy + rr * 0.8], fill=(255, 212, 138, int(1.7 * i)))
        frame.paste(glow, (0, 0), glow)
        fd = ImageDraw.Draw(frame, "RGBA")
        for i in (1, 2):
            fd.line([(pw * i / 3, 0), (pw * i / 3, ph)], fill=(255, 255, 255, 26), width=S)
            fd.line([(0, ph * i / 3), (pw, ph * i / 3)], fill=(255, 255, 255, 26), width=S)
        self.img.paste(frame, (px(x), px(y)))
        self.d = ImageDraw.Draw(self.img, "RGBA")


def knob(cv, cx, cy, size, value, detail, title, state):
    r = size / 2
    if state == "auto":
        cv.glass_circle(cx, cy, r, tint=YELLOW, ring=YELLOW_RING, sh=100)
        fg = DARK
    elif state == "sel":
        cv.glass_circle(cx, cy, r, tint=(255, 255, 255, 96), ring=(255, 255, 255, 225), sh=105)
        fg = WHITE
    elif state == "all":
        cv.glass_circle(cx, cy, r, tint=(255, 255, 255, 54), ring=(255, 255, 255, 150), sh=85)
        fg = WHITE
    else:
        cv.glass_circle(cx, cy, r, tint=(255, 255, 255, 20), ring=(255, 255, 255, 82), sh=60)
        fg = WHITE

    if state == "all":
        cv.text(cx, cy - 5, "A", F_KNOB, fg)
        cv.text(cx, cy + 11, "自动", F_CAP, fg)
        return
    cv.text(cx, cy - 8, value, F_KNOB, fg)
    if detail:
        cv.text(cx, cy + 4, detail, F_VAL, fg if state != "manual" else (255, 255, 255, 205))
    if title:
        cv.text(cx, cy + 15, title, F_CAP, fg if state != "manual" else (255, 255, 255, 135))


def lens_button(cv, cx, cy, size, label, active):
    if active:
        cv.glass_circle(cx, cy, size / 2, tint=(255, 255, 255, 120), ring=(255, 255, 255, 215), sh=95)
        fg = WHITE
    else:
        cv.glass_circle(cx, cy, size / 2, tint=(255, 255, 255, 16), ring=(255, 255, 255, 66), sh=55)
        fg = DIM
    cv.text(cx, cy, label, F_LENS, fg)


def gear_icon(cv, cx, cy, r):
    cv.d.ellipse([px(cx - r), px(cy - r), px(cx + r), px(cy + r)],
                 outline=(255, 255, 255, 220), width=px(1.6))
    import math
    for i in range(8):
        a = math.pi * i / 4
        cv.d.line([(px(cx + math.cos(a) * r), px(cy + math.sin(a) * r)),
                   (px(cx + math.cos(a) * r * 1.42), px(cy + math.sin(a) * r * 1.42))],
                  fill=(255, 255, 255, 220), width=px(1.6))


def orientation_button(cv, cx, cy, size):
    cv.glass_circle(cx, cy, size / 2, tint=(255, 255, 255, 26), ring=(255, 255, 255, 110), sh=45)
    import math
    r = size * 0.22
    cv.d.arc([px(cx - r), px(cy - r), px(cx + r), px(cy + r)], 40, 320,
             fill=(255, 255, 255, 235), width=px(1.6))
    tipx, tipy = cx + math.cos(math.radians(40)) * r, cy + math.sin(math.radians(40)) * r
    cv.d.polygon([(px(tipx), px(tipy)),
                  (px(tipx - 4), px(tipy - 1)),
                  (px(tipx + 1), px(tipy + 4))], fill=(255, 255, 255, 235))


def chips(cv, x, y):
    """两行状态读数：录制时间（带红点）+ 剩余时长，左对齐，无胶囊。"""
    cv.d.ellipse([px(x), px(y + 3), px(x + 4), px(y + 7)], fill=(255, 59, 48))
    cv.d.text((px(x + 8), px(y + 5)), "00:00:07", font=F_STATUS, fill=WHITE, anchor="lm")
    cv.d.text((px(x), px(y + 18)), "剩 1:12", font=F_STATUS, fill=(255, 255, 255, 184), anchor="lm")


def overlaps(a, b):
    return not (a[0] + a[2] <= b[0] or b[0] + b[2] <= a[0] or a[1] + a[3] <= b[1] or b[1] + b[3] <= a[1])


def report(title, boxes, intentional, limits, notes=(), full_bleed=None):
    print(f"\n=== {title} ===")
    for n, (x, y, w, h) in boxes.items():
        print(f"{n:9s} x {x:>6.1f}..{x + w:>6.1f}  y {y:>6.1f}..{y + h:>6.1f}  ({w:.1f}×{h:.1f})")
    ok = True
    print("--- 重叠 ---")
    names = list(boxes)
    for i in range(len(names)):
        for j in range(i + 1, len(names)):
            hit = overlaps(boxes[names[i]], boxes[names[j]])
            allowed = frozenset((names[i], names[j])) in intentional
            if hit and not allowed:
                ok = False
            print(f"{names[i]:9s} × {names[j]:9s}: {'重叠（设计如此）' if hit and allowed else ('重叠 ✗' if hit else '不重叠 ✓')}")
    print("--- 安全区 ---")
    W, H, il, ir, it, ib = limits
    for n, (x, y, w, h) in boxes.items():
        bleed = (full_bleed or {}).get(n)
        if bleed == "h":
            inside = abs(y) < 0.5 and abs(h - H) < 0.5
        elif bleed == "w":
            inside = abs(x) < 0.5 and abs(w - W) < 0.5
        else:
            inside = x >= il - 0.5 and x + w <= W - ir + 0.5 and y >= it - 0.5 and y + h <= H - ib + 0.5
        ok &= inside
        print(f"{n:9s} {'在安全区内 ✓' if inside else '越界 ✗'}")
    for n in notes:
        print(n)
    print("版式自检:", "通过" if ok else "未通过")
    return ok


# ============================================================
# 横屏 956×440
# ============================================================
def landscape():
    W, H = 956, 440
    IL, IR, IT, IB = 59, 59, 0, 21
    MARGIN, ASPECT = 8, 4224 / 3024
    KNOB, KNOB_GAP = 56, 8
    LENS, LENS_GAP = 44, 8
    BAR_W, LGAP, REC, GEAR, GAP = 52, 6, 56, 38, 12
    ORIENT = 30

    lens_h = LENS * 4 + LENS_GAP * 3
    lens_col = (IL + MARGIN, (H - lens_h) / 2, LENS, lens_h)
    gear = (lens_col[0], H - IB - MARGIN - GEAR, GEAR, GEAR)
    orient = (lens_col[0] + (LENS - ORIENT) / 2, lens_col[1] + lens_h + 10, ORIENT, ORIENT)

    preview_x = lens_col[0] + LENS + LGAP
    preview_w, preview_h = H * ASPECT, float(H)
    if preview_w > W * 0.78:
        preview_w, preview_h = W * 0.78, W * 0.78 / ASPECT
    preview = (preview_x, 0.0, preview_w, preview_h)

    bar = (W - IR - MARGIN - BAR_W, IT + MARGIN, BAR_W, H - IB - 2 * MARGIN)
    knob_x = bar[0] - GAP - KNOB
    knobs = (knob_x, (H - (KNOB * 6 + KNOB_GAP * 5)) / 2, KNOB, KNOB * 6 + KNOB_GAP * 5)
    rec = (preview_x + preview_w - 2 * MARGIN - REC, H - IB - MARGIN - REC, REC, REC)
    chip = (lens_col[0], 12)

    cv = Canvas(W, H)
    cv.preview(preview)

    ly = lens_col[1]
    for label, on in [("0.5×", False), ("1×", True), ("4×", False), ("8×", False)]:
        lens_button(cv, lens_col[0] + LENS / 2, ly + LENS / 2, LENS, label, on)
        ly += LENS + LENS_GAP
    orientation_button(cv, orient[0] + ORIENT / 2, orient[1] + ORIENT / 2, ORIENT)

    gx, gy, gw, gh = gear
    cv.glass_circle(gx + gw / 2, gy + gh / 2, gw / 2, tint=(255, 255, 255, 26), ring=(255, 255, 255, 110), sh=55)
    gear_icon(cv, gx + gw / 2, gy + gh / 2, 7)

    params = [("1/48", "AUTO", "快门", "auto"), ("640", "ISO", "", "manual"),
              ("0.42", "手动", "焦距", "sel"), ("+0.3", "AUTO", "曝光", "auto"),
              ("5600", "AUTO", "白平衡", "auto"), ("A", "自动", "", "all")]
    ky = knobs[1]
    for v, detail, cap, state in params:
        knob(cv, knobs[0] + KNOB / 2, ky + KNOB / 2, KNOB, v, detail, cap, state)
        ky += KNOB + KNOB_GAP

    bx, by, bw, bh = bar
    cv.glass_round(bx, by, bw, bh, bw / 2, tint=(255, 255, 255, 26), ring=(255, 255, 255, 88), sh=90)
    cv.text(bx + bw / 2, by + 26, "焦距", F_NAME, (255, 255, 255, 165))
    tx, ty0, ty1 = bx + bw / 2, by + 34, by + bh - 34
    cv.d.rounded_rectangle([px(tx - 3), px(ty0), px(tx + 3), px(ty1)], radius=px(3), fill=(255, 255, 255, 46))
    fy = ty1 - (ty1 - ty0) * 0.58
    cv.d.rounded_rectangle([px(tx - 3), px(fy), px(tx + 3), px(ty1)], radius=px(3), fill=(255, 255, 255, 200))
    cv.glass_circle(tx, fy, 11, tint=(255, 255, 255, 245), ring=(255, 255, 255, 255), sh=95)
    cv.text(tx, by + bh - 20, "0.42", F_NUM, WHITE)

    rx, ry, rw, rh = rec
    cv.glass_circle(rx + rw / 2, ry + rh / 2, rw / 2, tint=(255, 255, 255, 10), ring=(255, 255, 255, 90), sh=60)
    cv.d.ellipse([px(rx + rw / 2 - 11), px(ry + rh / 2 - 11), px(rx + rw / 2 + 11), px(ry + rh / 2 + 11)],
                 fill=(255, 59, 48))

    chips(cv, *chip)
    cv.img.save("F:/OpenGate/_design/landscape.png", "PNG")

    boxes = {"preview": preview, "lens": lens_col, "orient": orient, "knobs": knobs,
             "bar": bar, "rec": rec, "gear": gear, "status": (chip[0], chip[1], 46, 26)}
    ok = report("横屏 956×440", boxes, {frozenset(("preview", "rec"))}, (W, H, IL, IR, IT, IB),
                [f"取景高度 {preview_h:.1f}（应为 {H}）{'✓' if abs(preview_h - H) < 0.5 else '✗'}"],
                full_bleed={"preview": "h"})
    return ok


# ============================================================
# 竖屏 440×956
# ============================================================
def portrait():
    W, H = 440, 956
    IL, IR, IT, IB = 0, 0, 59, 34
    MARGIN, ASPECT = 12, 3024 / 4224
    KNOB_MAX, KNOB_GAP = 56, 8
    LENS, LENS_GAP, LENS_SLOTS = 44, 8, 4
    BAR_H, REC, GEAR, ORIENT = 56, 72, 38, 30

    knob_size = min(KNOB_MAX, max(40, (W - MARGIN * 2 - KNOB_GAP * 5) / 6))
    control_h = LENS + 10 + knob_size + 12 + BAR_H + 16 + REC
    usable_bottom = H - IB

    preview_h = W / ASPECT
    if preview_h + control_h + 12 > usable_bottom:
        preview_h = usable_bottom - control_h - 12
    preview_w = min(W, preview_h * ASPECT)
    preview = ((W - preview_w) / 2, 0.0, preview_w, preview_h)

    free = max(0, usable_bottom - preview_h - control_h)
    gap = min(max(10, free / 2), 34)
    y = preview_h + gap

    lens_w = (LENS * LENS_SLOTS + LENS_GAP * (LENS_SLOTS - 1)
              + LENS_GAP + ORIENT + LENS_GAP + GEAR)
    lens_row = ((W - lens_w) / 2, y, lens_w, LENS)
    y = lens_row[1] + LENS + 10

    knob_w = knob_size * 6 + KNOB_GAP * 5
    knob_row = ((W - knob_w) / 2, y, knob_w, knob_size)
    y = knob_row[1] + knob_size + 12

    bar = (IL + MARGIN, y, W - IL - IR - MARGIN * 2, BAR_H)
    y = bar[1] + BAR_H + 16
    rec = ((W - REC) / 2, y, REC, REC)
    chip = (IL + MARGIN, lens_row[1] + LENS / 2 - 13)

    cv = Canvas(W, H)
    cv.preview(preview)

    lx = lens_row[0]
    for label, on in [("0.5×", False), ("1×", True), ("4×", False), ("8×", False)]:
        lens_button(cv, lx + LENS / 2, lens_row[1] + LENS / 2, LENS, label, on)
        lx += LENS + LENS_GAP
    orientation_button(cv, lx + ORIENT / 2, lens_row[1] + LENS / 2, ORIENT)
    lx += ORIENT + LENS_GAP
    cv.glass_circle(lx + GEAR / 2, lens_row[1] + LENS / 2, GEAR / 2,
                    tint=(255, 255, 255, 26), ring=(255, 255, 255, 110), sh=55)
    gear_icon(cv, lx + GEAR / 2, lens_row[1] + LENS / 2, 7)

    params = [("1/48", "AUTO", "快门", "auto"), ("640", "ISO", "", "manual"),
              ("0.42", "手动", "焦距", "sel"), ("+0.3", "AUTO", "曝光", "auto"),
              ("5600", "AUTO", "白平衡", "auto"), ("A", "自动", "", "all")]
    kx = knob_row[0]
    for v, detail, cap, state in params:
        knob(cv, kx + knob_size / 2, knob_row[1] + knob_size / 2, knob_size, v, detail, cap, state)
        kx += knob_size + KNOB_GAP

    bx, by, bw, bh = bar
    cv.glass_round(bx, by, bw, bh, bh / 2, tint=(255, 255, 255, 26), ring=(255, 255, 255, 88), sh=90)
    cv.text(bx + 16 + 20, by + 13, "焦距", F_NAME, (255, 255, 255, 165))
    cv.text(bx + bw - 16 - 26, by + 13, "0.42", F_NUM, WHITE)
    sx0, sx1, sy = bx + 20, bx + bw - 20, by + bh - 17
    cv.d.rounded_rectangle([px(sx0), px(sy - 2.5), px(sx1), px(sy + 2.5)], radius=px(2.5), fill=(255, 255, 255, 46))
    fx = sx0 + (sx1 - sx0) * 0.58
    cv.d.rounded_rectangle([px(sx0), px(sy - 2.5), px(fx), px(sy + 2.5)], radius=px(2.5), fill=(255, 255, 255, 200))
    cv.glass_circle(fx, sy, 11, tint=(255, 255, 255, 245), ring=(255, 255, 255, 255), sh=95)

    rx, ry, rw, rh = rec
    cv.glass_circle(rx + rw / 2, ry + rh / 2, rw / 2, tint=(255, 255, 255, 10), ring=(255, 255, 255, 90), sh=60)
    cv.d.ellipse([px(rx + rw / 2 - 14), px(ry + rh / 2 - 14), px(rx + rw / 2 + 14), px(ry + rh / 2 + 14)],
                 fill=(255, 59, 48))

    chips(cv, *chip)
    cv.img.save("F:/OpenGate/_design/portrait.png", "PNG")

    boxes = {"preview": preview, "lens": lens_row, "knobs": knob_row,
             "bar": bar, "rec": rec, "status": (chip[0], chip[1], 46, 26)}
    ok = report("竖屏 440×956", boxes, set(), (W, H, IL, IR, IT, IB),
                [f"取景宽 {preview_w:.1f}（应为 {W}）{'✓' if abs(preview_w - W) < 0.5 else '✗'}",
                 f"圆钮直径 {knob_size:.1f}，钮行宽 {knob_w:.1f}"],
                full_bleed={"preview": "w"})
    return ok


a = landscape()
b = portrait()
print("\n总检:", "全部通过" if a and b else "有未通过项")
