# -*- coding: utf-8 -*-
"""MOV 层标记注入：在视频 sample entry 内写入 colr(nclc) 与 logs 标识

ffmpeg 的 mov muxer 不写 colr，Apple Log 2 也没有标准 nclc 编码，
所以这两项必须由本模块直接改容器字节完成。
"""
import struct

CONTAINERS = {b'moov', b'trak', b'mdia', b'minf', b'stbl', b'udta', b'edts', b'dinf', b'wave', b'tref'}


def _boxes(buf, start, end):
    i = start
    while i + 8 <= end:
        sz = struct.unpack('>I', buf[i:i+4])[0]
        typ = bytes(buf[i+4:i+8])
        hdr = 8
        if sz == 1:
            if i + 16 > end: break
            sz = struct.unpack('>Q', buf[i+8:i+16])[0]
            hdr = 16
        elif sz == 0:
            sz = end - i
        if sz < hdr or i + sz > end: break
        yield typ, i, sz, hdr
        i += sz


def _find_path(buf, start, end, path):
    nodes = []
    cur_s, cur_e = start, end
    for want in path:
        hit = None
        for typ, off, sz, hdr in _boxes(buf, cur_s, cur_e):
            if typ == want:
                hit = (off, sz, hdr); break
        if hit is None: return None
        nodes.append(hit)
        cur_s, cur_e = hit[0] + hit[2], hit[0] + hit[1]
    return nodes


def _mk_colr(primaries, transfer, matrix):
    return struct.pack('>I4s4sHHH', 18, b'colr', b'nclc', primaries, transfer, matrix)


def _mk_logs(identifier):
    # 官方样本里 logs 的 body 就是裸标识符，没有 null 结尾
    # （IMG_0032-1.mov: 44 字节 box = 8 header + 36 字节字符串）
    payload = identifier.encode('ascii')
    return struct.pack('>I4s', 8 + len(payload), b'logs') + payload


def _set_size(buf, off, hdr, new_size):
    if hdr == 16:
        struct.pack_into('>I', buf, off, 1)
        struct.pack_into('>Q', buf, off + 8, new_size)
    else:
        struct.pack_into('>I', buf, off, new_size)


def _pick_video_entry(buf):
    moov = None
    for typ, off, sz, hdr in _boxes(buf, 0, len(buf)):
        if typ == b'moov':
            moov = (off, sz, hdr); break
    if not moov:
        raise RuntimeError('没有 moov')
    m_off, m_sz, m_hdr = moov
    for t2, to, tsz, th in _boxes(buf, m_off+m_hdr, m_off+m_sz):
        if t2 != b'trak': continue
        nodes = _find_path(buf, to+th, to+tsz, [b'mdia', b'minf', b'stbl', b'stsd'])
        if not nodes: continue
        s_off, s_sz, s_hdr = nodes[-1]
        for et, eo, es, eh in _boxes(buf, s_off+s_hdr+8, s_off+s_sz):
            if et in (b'hvc1', b'hev1'):
                return dict(moov=moov, trak=(to, tsz, th), chain=nodes, entry=(eo, es, eh))
    raise RuntimeError('没有 hvc1 sample entry')


def describe(path):
    buf = open(path, 'rb').read()
    out = dict(size=len(buf))
    for typ, off, sz, hdr in _boxes(buf, 0, len(buf)):
        if typ == b'mdat':
            out['mdat_offset'] = off
    try:
        p = _pick_video_entry(buf)
    except Exception:
        return out
    _, s_sz, s_hdr = p['chain'][-1]
    e_off, e_sz, e_hdr = p['entry']
    out['entry_offset'] = e_off
    for ct, co, cs, ch in _boxes(buf, e_off+e_hdr+78, e_off+e_sz):
        if ct == b'colr':
            body = bytes(buf[co+ch:co+cs])
            if body[:4] == b'nclc':
                out['colr'] = dict(primaries=struct.unpack('>H', body[4:6])[0],
                                   transfer=struct.unpack('>H', body[6:8])[0],
                                   matrix=struct.unpack('>H', body[8:10])[0])
            else:
                out['colr'] = dict(raw=body.hex(' '))
        elif ct == b'logs':
            out['logs'] = bytes(buf[co+ch:co+cs]).rstrip(b'\x00').decode('ascii', 'replace')
    return out


def inject(input_path, output_path=None, primaries=9, transfer=2, matrix=9,
           log_id='com.apple.apple-wide-gamut.apple-log'):
    out = output_path or input_path
    buf = bytearray(open(input_path, 'rb').read())
    p = _pick_video_entry(buf)
    m_off, m_sz, m_hdr = p['moov']
    s_off, s_sz, s_hdr = p['chain'][-1]
    e_off, e_sz, e_hdr = p['entry']
    vh = 78

    # 重建 entry：保留原有子 box（去掉 colr/logs），末尾追加新的
    kids = []
    for ct, co, cs, ch in _boxes(buf, e_off+e_hdr+vh, e_off+e_sz):
        if ct in (b'colr', b'logs'):
            continue
        kids.append(bytes(buf[co:co+cs]))
    kids.append(_mk_colr(primaries, transfer, matrix))
    # 空标识符表示已烧过 LUT、不再是 Log 素材，不写 logs atom
    if log_id:
        kids.append(_mk_logs(log_id))

    head = bytes(buf[e_off:e_off+e_hdr+vh])            # size+type+固定头(78)
    entry_type = bytes(buf[e_off+4:e_off+8])
    fixed = head[e_hdr:]                               # 78 字节固定头
    body = fixed + b''.join(kids)
    new_entry = struct.pack('>I', 8+len(body)) + entry_type + body

    # 重建 stsd：替换目标 entry，保留其余
    entries = bytearray()
    for et, eo, es, eh in _boxes(buf, s_off+s_hdr+8, s_off+s_sz):
        entries += new_entry if eo == e_off else bytes(buf[eo:eo+es])
    stsd_head = bytes(buf[s_off:s_off+s_hdr+8])        # size+type+verflags+count
    new_stsd = struct.pack('>I', len(stsd_head)+len(entries)) + bytes(buf[s_off+4:s_off+8]) \
               + stsd_head[s_hdr:] + bytes(entries)

    delta = len(new_stsd) - s_sz
    buf[s_off:s_off+s_sz] = new_stsd

    for off, sz, hdr in p['chain'][:-1] + [p['trak']]:
        _set_size(buf, off, hdr, sz + delta)
    _set_size(buf, m_off, m_hdr, m_sz + delta)

    shifted = 0
    if delta != 0:
        for typ, off, sz, hdr in _boxes(buf, 0, len(buf)):
            if typ != b'moov': continue
            for t2, to2, tsz2, th2 in _boxes(buf, off+hdr, off+sz):
                if t2 != b'trak': continue
                nd = _find_path(buf, to2+th2, to2+tsz2, [b'mdia', b'minf', b'stbl'])
                if not nd: continue
                b_off, b_sz, b_hdr = nd[-1]
                for t3, c_off, c_sz, c_hdr in _boxes(buf, b_off+b_hdr, b_off+b_sz):
                    if t3 == b'stco': shifted += _shift_stco(buf, c_off, c_sz, c_hdr, s_off, delta)
                    elif t3 == b'co64': shifted += _shift_co64(buf, c_off, c_sz, c_hdr, s_off, delta)

    open(out, 'wb').write(bytes(buf))
    return dict(primaries=primaries, transfer=transfer, matrix=matrix, logs_id=log_id,
                delta=delta, chunks_shifted=shifted, path=out)


def _shift_stco(buf, off, sz, hdr, threshold, delta):
    n = struct.unpack_from('>I', buf, off+hdr+4)[0]
    base = off+hdr+8; cnt = 0
    for k in range(n):
        q = base+4*k
        v = struct.unpack_from('>I', buf, q)[0]
        if v >= threshold:
            struct.pack_into('>I', buf, q, v+delta); cnt += 1
    return cnt


def _shift_co64(buf, off, sz, hdr, threshold, delta):
    n = struct.unpack_from('>I', buf, off+hdr+4)[0]
    base = off+hdr+8; cnt = 0
    for k in range(n):
        q = base+8*k
        v = struct.unpack_from('>Q', buf, q)[0]
        if v >= threshold:
            struct.pack_into('>Q', buf, q, v+delta); cnt += 1
    return cnt
