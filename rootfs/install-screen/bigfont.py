# bigfont.py IN OUT: write OUT, a PSF2 console font of double width and double
# height (16x32 from an 8x16 PSF1 or PSF2 font, for example the Terminus 8x16
# of tsx-splash). The glyphs are the same, each pixel 2x2. No Unicode table
# (ASCII maps 1:1 in Terminus). Standard library only; run with python3 -I.
import struct
import sys


def read(path):
    b = open(path, "rb").read()
    if b[:2] == b"\x36\x04":                      # PSF1
        mode, h = b[2], b[3]
        n = 512 if mode & 1 else 256
        return 8, h, n, b[4:4 + n * h]
    if b[:4] == b"\x72\xb5\x4a\x86":              # PSF2
        _, _, hsize, _, n, size, h, w = struct.unpack("<8I", b[:32])
        return w, h, n, b[hsize:hsize + n * size]
    raise SystemExit("not a PSF font: %s" % path)


def main():
    src, out = sys.argv[1:3]
    w, h, n, data = read(src)
    rb = (w + 7) // 8                              # bytes per row of the source
    w2, h2 = 2 * w, 2 * h
    rb2 = (w2 + 7) // 8
    glyphs = bytearray()
    for g in range(n):
        rows = data[g * rb * h:(g + 1) * rb * h]
        for y in range(h):
            bits = int.from_bytes(rows[y * rb:(y + 1) * rb], "big") >> (rb * 8 - w)
            wide = 0
            for x in range(w):
                if bits >> (w - 1 - x) & 1:
                    wide |= 3 << (2 * (w - 1 - x))
            row = (wide << (rb2 * 8 - w2)).to_bytes(rb2, "big")
            glyphs += row + row
    head = struct.pack("<8I", 0x864AB572, 0, 32, 0, n, rb2 * h2, h2, w2)
    with open(out + ".tmp", "wb") as f:
        f.write(head + glyphs)
    import os
    os.replace(out + ".tmp", out)


main()
