"""Bit-exact reference of image_fit_scaler (rtl/storage/bmp24_decoder.v) and helpers.

fit_frame(rows, W, H, top_down) -> 640x480 list of (r, g, b) in display order, where rows
is the list of source rows in FILE order (each a list of (r, g, b)), exactly as the RTL
receives them. write_bmp() writes 24-bit BMPs, optionally top-down (negative height).
"""
import struct

OUT_W, OUT_H = 640, 480
RECIP = [0, 65536, 32768, 21845, 16384, 13107, 10923, 9362, 8192]

def _avg(total, n):
    return min(255, (total * RECIP[n] + 32768) >> 16)

def _lerp(a, b, f):
    return a + (((b - a) * f + 128) >> 8)

def geometry(W, H, out_w=OUT_W, out_h=OUT_H):
    prod_a, prod_b = W * out_h, H * out_w
    if prod_a >= prod_b:
        q = (prod_b + (W >> 1)) // W
        fw, fh = out_w, 1 if q == 0 else min(q, out_h)
    else:
        q = (prod_a + (H >> 1)) // H
        fh, fw = out_h, 1 if q == 0 else min(q, out_w)
    x0, y0 = (out_w - fw) >> 1, (out_h - fh) >> 1
    return fw, fh, x0, y0, W < out_w and H < out_h

def _down(rows, W, H, fw, fh):
    acc = [[0, 0, 0] for _ in range(fw)]
    out, tv, vcnt = [], 0, 0
    for row in rows:
        emit = tv + fh >= H
        th, hs, hc, col, line = 0, [0, 0, 0], 0, 0, []
        for p in row:
            hs = [hs[c] + p[c] for c in range(3)]; hc += 1
            tn = th + fw
            if tn >= W:
                th = tn - W
                hv = [_avg(hs[c], hc) for c in range(3)]
                vs = [acc[col][c] + hv[c] for c in range(3)]
                if emit:
                    line.append(tuple(_avg(vs[c], vcnt + 1) for c in range(3))); acc[col] = [0, 0, 0]
                else:
                    acc[col] = vs
                hs, hc, col = [0, 0, 0], 0, col + 1
            else:
                th = tn
        if emit:
            out.append(line); tv, vcnt = tv + fh - H, 0
        else:
            tv, vcnt = tv + fh, vcnt + 1
    assert len(out) == fh
    return out

def _up(rows, W, H, fw, fh):
    step_x = ((W - 1) << 16) // (fw - 1)
    step_y = ((H - 1) << 16) // (fh - 1)
    out = []
    for j in range(fh):
        sy = j * step_y; y0 = sy >> 16; y1 = min(y0 + 1, H - 1)
        fy = 0 if y1 == y0 else (sy >> 8) & 255
        line = []
        for i in range(fw):
            sx = i * step_x; x = sx >> 16; fx = (sx >> 8) & 255
            def hor(r):
                a = rows[r][x]
                return a if fx == 0 else tuple(_lerp(a[c], rows[r][x + 1][c], fx) for c in range(3))
            ht = hor(y0)
            line.append(ht if fy == 0 else tuple(_lerp(ht[c], hor(y1)[c], fy) for c in range(3)))
        out.append(line)
    return out

def fit_frame(rows, W, H, top_down, out_w=OUT_W, out_h=OUT_H):
    fw, fh, x0, y0, up = geometry(W, H, out_w, out_h)
    body = _up(rows, W, H, fw, fh) if up else _down(rows, W, H, fw, fh)
    black = (0, 0, 0)
    file_rows = [[black] * out_w for _ in range(y0)]
    file_rows += [[black] * x0 + line + [black] * (out_w - x0 - fw) for line in body]
    file_rows += [[black] * out_w for _ in range(out_h - y0 - fh)]
    return file_rows if top_down else file_rows[::-1]

def read_bmp_rows(path):
    """Source rows in FILE order, plus W, H, top_down (24-bit uncompressed only)."""
    data = open(path, 'rb').read()
    off, W, h = struct.unpack_from('<I', data, 10)[0], *struct.unpack_from('<ii', data, 18)
    H, top_down = abs(h), h < 0
    stride = (W * 3 + 3) & ~3
    rows = []
    for r in range(H):
        base = off + r * stride
        rows.append([(data[base + 3 * x + 2], data[base + 3 * x + 1], data[base + 3 * x]) for x in range(W)])
    return rows, W, H, top_down

def write_bmp(path, pixels, top_down=False):
    """pixels: list of display rows (top first) of (r, g, b)."""
    H, W = len(pixels), len(pixels[0]); stride = (W * 3 + 3) & ~3
    body = bytearray()
    for row in (pixels if top_down else pixels[::-1]):
        line = bytearray()
        for r, g, b in row: line += bytes((b, g, r))
        body += line + bytes(stride - len(line))
    header = struct.pack('<2sIHHIIiiHHIIiiII', b'BM', 54 + len(body), 0, 0, 54, 40, W, -H if top_down else H,
                         1, 24, 0, len(body), 2835, 2835, 0, 0)
    open(path, 'wb').write(header + body)

def checksums(frame):
    """Sum and position-weighted sum (mod 2^32) of 24-bit words, display order."""
    s = w = 0
    for k, (r, g, b) in enumerate(p for row in frame for p in row):
        v = (r << 16) | (g << 8) | b; s += v; w += v * (k + 1)
    return s & 0xffffffff, w & 0xffffffff
