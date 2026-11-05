"""Draws the hop frog into assets/hop.ico and assets/brand/*.png. Needs only Python 3.

Run from the project root: python3 tools/make_icon.py
The shapes match assets/brand/hop-mark.svg, on the same 100 by 100 grid.
"""
import math, struct, zlib

TILE = (34, 177, 76)
FROG = (255, 255, 255)
MARK = (23, 166, 72)


def in_circle(x, y, cx, cy, r):
    return (x - cx) ** 2 + (y - cy) ** 2 <= r * r


def in_frog(x, y):
    if in_circle(x, y, 29, 36, 19) or in_circle(x, y, 71, 36, 19):
        return True
    if y <= 76:
        return ((x - 50) / 44) ** 2 + ((y - 76) / 40) ** 2 <= 1
    if y > 86:
        return False
    return 16 <= x <= 84 or in_circle(x, y, 16, 76, 10) or in_circle(x, y, 84, 76, 10)


def in_pupil(x, y, r):
    return in_circle(x, y, 29, 36, r) or in_circle(x, y, 71, 36, r)


def in_tile(x, y):
    half, radius = 0.48, 0.225
    qx, qy = abs(x - 0.5) - (half - radius), abs(y - 0.5) - (half - radius)
    return math.hypot(max(qx, 0), max(qy, 0)) + min(max(qx, qy), 0) - radius <= 0


def render(size, tile=True):
    # Small icons get a bigger frog and bigger pupils, or the eyes fill in.
    small = size <= 32
    scale, pupil = (0.80, 8) if small else (0.70, 6.5)
    if not tile:
        scale = 1
    samples = 6 if size < 48 else 4
    pixels = []
    for py in range(size):
        row = []
        for px in range(size):
            acc = [0.0, 0.0, 0.0, 0.0]
            for sy in range(samples):
                for sx in range(samples):
                    x = (px + (sx + 0.5) / samples) / size
                    y = (py + (sy + 0.5) / samples) / size
                    gx = (x - 0.5) / scale * 100 + 50
                    gy = (y - 0.5) / scale * 100 + 51.5
                    on_frog = in_frog(gx, gy) and not in_pupil(gx, gy, pupil)
                    if tile:
                        if not in_tile(x, y):
                            continue
                        color = FROG if on_frog else TILE
                    else:
                        if not on_frog:
                            continue
                        color = MARK
                    acc[0] += color[0]; acc[1] += color[1]; acc[2] += color[2]; acc[3] += 1
            if acc[3]:
                row.append((round(acc[0] / acc[3]), round(acc[1] / acc[3]), round(acc[2] / acc[3]), round(acc[3] / samples ** 2 * 255)))
            else:
                row.append((0, 0, 0, 0))
        pixels.append(row)
    return pixels


def png(pixels):
    size = len(pixels)
    raw = b''.join(b'\x00' + bytes(c for p in row for c in p) for row in pixels)
    def chunk(kind, data):
        return struct.pack('>I', len(data)) + kind + data + struct.pack('>I', zlib.crc32(kind + data) & 0xffffffff)
    return (b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', size, size, 8, 6, 0, 0, 0))
            + chunk(b'IDAT', zlib.compress(raw, 9)) + chunk(b'IEND', b''))


def dib(pixels):
    # Classic icon image: BITMAPINFOHEADER, bottom-up BGRA, then a 1-bit AND mask.
    size = len(pixels)
    header = struct.pack('<IiiHHIIiiII', 40, size, size * 2, 1, 32, 0, 0, 0, 0, 0, 0)
    color = b''.join(bytes((b, g, r, a)) for row in reversed(pixels) for (r, g, b, a) in row)
    stride = ((size + 31) // 32) * 4
    mask = b''
    for row in reversed(pixels):
        bits = bytearray(stride)
        for x, p in enumerate(row):
            if p[3] == 0:
                bits[x // 8] |= 0x80 >> (x % 8)
        mask += bytes(bits)
    return header + color + mask


def main():
    sizes = [16, 20, 24, 32, 40, 48, 64, 256]
    images = [png(render(s)) if s == 256 else dib(render(s)) for s in sizes]
    data = struct.pack('<HHH', 0, 1, len(sizes))
    offset = 6 + 16 * len(sizes)
    for s, img in zip(sizes, images):
        data += struct.pack('<BBBBHHII', s % 256, s % 256, 0, 0, 1, 32, len(img), offset)
        offset += len(img)
    data += b''.join(images)
    open('assets/hop.ico', 'wb').write(data)
    open('assets/brand/hop-icon-256.png', 'wb').write(images[-1])
    open('assets/brand/hop-mark-64.png', 'wb').write(png(render(64, tile=False)))


main()
