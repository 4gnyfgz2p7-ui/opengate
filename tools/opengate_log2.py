# -*- coding: utf-8 -*-
"""
OpenGate ProRes RAW → Apple Log 2 转码器

链路（与手机侧完全解耦，纯 CPU 实现）
    ProRes RAW(aprn) ──ffmpeg 熵解码+IDCT──> 16bit Bayer
      → 白点归一 (raw/65520)
      → 双线性 demosaic (RGGB)
      → camera native RGB → Apple Wide Gamut   (帧头 ColorMatrix 合成 XYZ→AWG)
      → Apple Log 2 曲线 (γ=0.08550479 β=0.00964052 δ=0.69336945, toe c=47.28711236)
      → HEVC Main10 4:2:0, BT.2020 矩阵, video range
      → MOV 注入 colr(9/2/9) + logs(com.apple.rec2020.apple-log)

用法
    python opengate_log2.py 输入.mov [-o 输出.mov] [--bitrate 45M] [--maxrate 90M]
    python opengate_log2.py --tag-only 已有.mov        # 只补色彩标记，不重编码
    python opengate_log2.py --probe 文件.mov           # 只读诊断
"""
import argparse
import os
import struct
import subprocess
import sys
import tempfile
import time

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import movtag

FF_CANDIDATES = [
    r"D:/VideoEnhance/tools/ffmpeg/bin/ffmpeg.exe",
    r"C:/ffmpeg/bin/ffmpeg.exe",
    "ffmpeg",
]

# ---------------- 常量（Apple 白皮书 / Apple Wide Gamut） ----------------
LOG_GAMMA = np.float32(0.08550479)
LOG_BETA = np.float32(0.00964052)
LOG_DELTA = np.float32(0.69336945)
LOG_C = np.float32(47.28711236)
LOG_R0 = np.float32(-0.05641088)
LOG_RT = np.float32(0.01)

AWG_PRIMARIES = [(0.725, 0.301), (0.221, 0.814), (0.068, -0.076)]
BT709_PRIMARIES = [(0.64, 0.33), (0.30, 0.60), (0.15, 0.06)]
D65 = (0.95047, 1.0, 1.08883)
CAM2XYZ = np.array([[0.31069, 0.35744, 0.28234],
                    [0.11647, 0.74624, 0.13730],
                    [0.03845, -0.17685, 1.22723]], np.float64)

WHITE_LEVEL = 65520.0
BLACK_LEVEL = 256.0


def find_ffmpeg():
    for c in FF_CANDIDATES:
        if c == "ffmpeg" or os.path.exists(c):
            return c
    raise RuntimeError("找不到 ffmpeg")


def prim_to_xyz(prim, white=D65):
    cols = [[x / y, 1.0, (1 - x - y) / y] for x, y in prim]
    M = np.array(cols, np.float64).T
    return M * np.linalg.solve(M, np.array(white, np.float64))


XYZ2AWG = np.linalg.inv(prim_to_xyz(AWG_PRIMARIES))
CAM2AWG = (XYZ2AWG @ CAM2XYZ).astype(np.float32)
AWG2_709 = (np.linalg.inv(prim_to_xyz(BT709_PRIMARIES)) @ prim_to_xyz(AWG_PRIMARIES)).astype(np.float32)


def apple_log(r):
    return np.where(r >= LOG_RT,
                    LOG_GAMMA * np.log2(np.maximum(r + LOG_BETA, np.float32(1e-9))) + LOG_DELTA,
                    np.where(r >= LOG_R0, LOG_C * np.square(r - LOG_R0), np.float32(0)))


def inv_apple_log(y):
    y = np.asarray(y, np.float32)
    return np.where(y >= LOG_RT,
                    np.exp2((y - LOG_DELTA) / LOG_GAMMA) - LOG_BETA,
                    LOG_R0 + np.sqrt(np.maximum(y, 0) / LOG_C))


# ---------------- ProRes RAW 帧头 ----------------
def probe_raw(path):
    """扫描 mdat 里的 prrf 帧头，读尺寸/白点/矩阵/BayerPattern"""
    info = dict(path=path, patched=False, frames=0)
    sig = b'prrf'
    with open(path, 'rb') as f:
        # 帧头最大 152 字节，只需扫分块
        f.seek(0)
        prev = b''
        pos = 0
        first = True
        while True:
            chunk = f.read(1 << 22)
            if not chunk:
                break
            buf = prev + chunk
            i = 0
            while True:
                j = buf.find(sig, i)
                if j < 0:
                    break
                base = j - 4                      # 帧起点
                if first and base >= 0 and j + 0x50 < len(buf):
                    h = buf[j:j + 0x50]           # h[0:4]='prrf'
                    info['frame_header_len'] = struct.unpack('>H', h[4:6])[0]
                    info['width'] = struct.unpack('>H', h[0x0c:0x0e])[0]
                    info['height'] = struct.unpack('>H', h[0x0e:0x10])[0]
                    info['pattern'] = struct.unpack('>H', h[0x14:0x16])[0]
                    info['sensel_range'] = struct.unpack('>H', h[0x16:0x18])[0]
                    info['wb_r'] = round(struct.unpack('>f', h[0x18:0x1c])[0], 5)
                    info['wb_b'] = round(struct.unpack('>f', h[0x1c:0x20])[0], 5)
                    cm = struct.unpack('>9f', h[0x20:0x44])
                    info['camera_matrix'] = [round(v, 5) for v in cm]
                    info['gain'] = round(struct.unpack('>f', h[0x44:0x48])[0], 5)
                    info['cct'] = struct.unpack('>H', h[0x48:0x4a])[0]
                    info['patched'] = info['pattern'] == 0
                    first = False
                info['frames'] += 1
                i = j + 1
            prev = buf[-256:]
            pos += len(chunk)
    return info


def patch_bayer_pattern(src, dst=None):
    """把 BayerPattern 从 3 改成 0，让 ffmpeg 的 prores_raw 解码器输出平面"""
    dst = dst or src
    data = bytearray(open(src, 'rb').read())
    sig = b'prrf'
    n = 0
    i = 0
    while True:
        j = data.find(sig, i)
        if j < 0:
            break
        p = j + 0x14
        if data[p:p + 2] == b'\x00\x03':
            data[p:p + 2] = b'\x00\x00'
            n += 1
        i = j + 1
    out = dst if dst != src else src + '.patched.mov'
    with open(out, 'wb') as f:
        f.write(data)
    return out, n


# ---------------- 图像处理 ----------------
def box3(a):
    p = np.pad(a, 1, mode='reflect')
    s = np.zeros_like(a)
    for dy in range(3):
        for dx in range(3):
            s += p[dy:dy + a.shape[0], dx:dx + a.shape[1]]
    return s


def demosaic(x):
    pl = {k: np.zeros_like(x) for k in 'RGB'}
    mk = {k: np.zeros_like(x) for k in 'RGB'}
    for (yy, xx), c in zip([(0, 0), (0, 1), (1, 0), (1, 1)], ('R', 'G', 'G', 'B')):
        pl[c][yy::2, xx::2] = x[yy::2, xx::2]
        mk[c][yy::2, xx::2] = 1.0
    return {c: box3(pl[c]) / np.maximum(box3(mk[c]), 1e-6) for c in 'RGB'}


def frame_to_log2(raw, gain=1.0):
    # gain 取自 prrf 帧头的 GainFactor。传感器增益必须乘进来，否则整体会
    # 暗约 gain 倍（实测 2.977 → 中位线性 0.052 而非 0.153）。
    # 该画面 p99.9 线性值 0.63，乘 2.977 后经 Log 曲线落在 0.772，不会削顶。
    lin = np.clip(raw * gain / WHITE_LEVEL, 0, 1)
    c = demosaic(lin)
    rgb = np.stack([c['R'], c['G'], c['B']], -1)
    awg = np.clip(rgb @ CAM2AWG.T, 0, None)
    return np.clip(apple_log(awg), 0, 1)


# ---------------- 转码主流程 ----------------
def transcode(src, dst, bitrate="45M", maxrate="90M", preset="medium", fps=None,
              transfer_fn=None, log=print):
    ff = find_ffmpeg()
    info = probe_raw(src)
    log(f"源：{os.path.basename(src)}")
    log(f"  帧头 pattern={info.get('pattern')}  whiterange={info.get('sensel_range')}  "
        f"gain={info.get('gain', 0):.4f}  CCT={info.get('cct')}K")
    log(f"  camera→XYZ 行和 "
        f"{[round(sum(info['camera_matrix'][r*3:r*3+3]), 4) for r in range(3)]}")

    work = src
    cleanup = []
    if not info.get('patched'):
        work, n = patch_bayer_pattern(src)
        cleanup.append(work)
        log(f"  BayerPattern 3→0 已改写 {n} 帧 → {os.path.basename(work)}")

    # 用 ffprobe 取尺寸与音频
    dims = subprocess.run([ff, "-hide_banner", "-i", src], capture_output=True, text=True, errors='replace').stderr
    vline = [l for l in dims.splitlines() if 'Video:' in l][0]
    import re
    m = re.search(r'(\d{3,5})x(\d{3,5})', vline)
    W, H = int(m.group(1)), int(m.group(2))
    has_audio = 'Audio:' in dims
    log(f"  分辨率 {W}x{H}  音频 {'有' if has_audio else '无'}")

    tmp_out = dst + ".enc.mov"
    dec = subprocess.Popen([ff, "-hide_banner", "-loglevel", "error", "-noautorotate", "-i", work,
                            "-pix_fmt", "bayer_rggb16le", "-f", "rawvideo", "-"],
                           stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)

    cmd = [ff, "-hide_banner", "-loglevel", "error",
           "-f", "rawvideo", "-pix_fmt", "rgb48le", "-s", f"{W}x{H}", "-r", str(fps or 24), "-i", "-"]
    if has_audio:
        cmd += ["-i", src, "-map", "0:v:0", "-map", "1:a:0", "-c:a", "copy"]
    else:
        cmd += ["-map", "0:v:0"]
    cmd += ["-c:v", "libx265", "-pix_fmt", "yuv420p10le",
            "-b:v", bitrate, "-maxrate", maxrate, "-bufsize", maxrate,
            "-preset", preset, "-tag:v", "hvc1",
            "-color_range", "tv",
            "-color_primaries", "bt2020", "-color_trc", "bt709", "-colorspace", "bt2020nc",
            "-y", tmp_out]
    enc = subprocess.Popen(cmd, stdin=subprocess.PIPE, stderr=subprocess.DEVNULL)

    FB = W * H * 2
    n = 0
    t0 = time.time()
    probe_frames = []
    while True:
        buf = dec.stdout.read(FB)
        if len(buf) < FB:
            break
        raw = np.frombuffer(buf, dtype=np.uint16).reshape(H, W).astype(np.float32)
        logv = frame_to_log2(raw, gain=info.get('gain', 1.0) or 1.0)
        u16 = (np.clip(logv, 0, 1) * 65535.0 + 0.5).astype(np.uint16)
        try:
            enc.stdin.write(u16.tobytes())
        except BrokenPipeError:
            log("编码器提前退出"); break
        if n in (0, 24, 48):
            probe_frames.append(logv)
        n += 1
        if n % 24 == 0:
            el = time.time() - t0
            log(f"  {n:4d} 帧  {el:5.1f}s  {n/el:.2f} fps")

    dec.stdout.close(); enc.stdin.close(); dec.wait(); enc.wait()
    log(f"编码完成 {n} 帧 / {time.time()-t0:.1f}s")

    rep = movtag.inject(tmp_out, dst, primaries=9, transfer=2, matrix=9)
    os.remove(tmp_out)
    for f in cleanup:
        if os.path.exists(f):
            os.remove(f)
    log(f"标记注入 colr={rep['primaries']}/{rep['transfer']}/{rep['matrix']}  "
        f"logs={rep['logs_id']}  (+{rep['delta']}B, 修正 {rep['chunks_shifted']} 个 chunk)")

    return dict(frames=n, width=W, height=H, has_audio=has_audio,
                probes=probe_frames, size=os.path.getsize(dst))


# ---------------- 自检 ----------------
def self_check(path, probes=None, log=print):
    ff = find_ffmpeg()
    res = []
    ok = lambda c, m: res.append((('PASS' if c else 'FAIL'), m))

    d = movtag.describe(path)
    c = d.get('colr', {})
    ok(c.get('primaries') == 9 and c.get('transfer') == 2 and c.get('matrix') == 9,
       f"colr nclc = {c.get('primaries')}/{c.get('transfer')}/{c.get('matrix')}（官方 9/2/9）")
    ok(d.get('logs') == 'com.apple.rec2020.apple-log',
       f"logs 标识 = {d.get('logs')}")

    line = subprocess.run([ff, "-hide_banner", "-i", path], capture_output=True,
                          text=True, errors='replace').stderr
    v = [l for l in line.splitlines() if 'Video:' in l][0]
    ok('yuv420p10le' in v, "像素格式 yuv420p10le")
    ok('Main 10' in v, "编码 Main 10")
    ok('(tv,' in v or ', tv,' in v, "range = video（与 Apple 官方一致）")
    ok('bt2020nc' in v, "YUV 矩阵 = BT.2020 non-constant")

    # 曲线数值
    g = apple_log(np.float32(0.18))
    ok(abs(g - 0.4882724) < 1e-5, f"18% 灰 → {g:.6f}（白皮书 0.488272）")
    probe = np.array([0.01, 0.05, 0.18, 0.5, 1.0], np.float32)
    err = np.abs(inv_apple_log(apple_log(probe)) - probe).max()
    ok(err < 1e-4, f"曲线可逆误差 {err:.2e}")
    ok(np.allclose(CAM2AWG.sum(1), 1, atol=1e-5) and np.allclose(AWG2_709.sum(1), 1, atol=1e-5),
       "色彩矩阵行和为 1（中性灰不漂移）")

    # 曝光落点
    if probes:
        W, H = None, None
        Ys = []
        for lg in probes:
            Y = 0.2126 * lg[..., 0] + 0.7152 * lg[..., 1] + 0.0722 * lg[..., 2]
            Ys.append(np.percentile(Y, 50))
        mid = float(np.mean(Ys))
        code = 64 + mid * 876
        delta = (mid - 0.4882724) * 876
        res.append(('INFO', f"中位 Log 值 {mid:.4f} → video 码 {code:.0f}/1023"
                            f"（18% 灰基准 492，差 {delta:+.0f}）"))
        res.append(('INFO', f"反推场景线性 {float(inv_apple_log(mid)):.4f}"
                            f"（18% 灰卡 = 0.1800）"))

    log("")
    log("=" * 66)
    log("自检")
    log("=" * 66)
    bad = 0
    for tag, msg in res:
        log(f"  [{tag}] {msg}")
        if tag == 'FAIL':
            bad += 1
    log("=" * 66)
    log(f"  {'全部通过' if bad == 0 else f'{bad} 项未通过'}")
    return bad == 0


def main():
    ap = argparse.ArgumentParser(description="ProRes RAW → Apple Log 2")
    ap.add_argument("input")
    ap.add_argument("-o", "--output")
    ap.add_argument("--bitrate", default="45M")
    ap.add_argument("--maxrate", default="90M")
    ap.add_argument("--preset", default="medium")
    ap.add_argument("--fps", type=float)
    ap.add_argument("--tag-only", action="store_true", help="只注入色彩标记，不重编码")
    ap.add_argument("--probe", action="store_true", help="只打印源诊断")
    a = ap.parse_args()

    if a.probe:
        import json
        print(json.dumps(probe_raw(a.input), indent=2, ensure_ascii=False))
        print(json.dumps(movtag.describe(a.input), indent=2, ensure_ascii=False))
        return

    if a.tag_only:
        out = a.output or a.input
        print(movtag.inject(a.input, out))
        self_check(out)
        return

    out = a.output or os.path.splitext(a.input)[0] + "_AppleLog2.mov"
    r = transcode(a.input, out, a.bitrate, a.maxrate, a.preset, a.fps)
    print(f"\n输出 {out}  {r['size']/1048576:.1f} MB")
    good = self_check(out, r['probes'])
    sys.exit(0 if good else 1)


if __name__ == "__main__":
    main()
