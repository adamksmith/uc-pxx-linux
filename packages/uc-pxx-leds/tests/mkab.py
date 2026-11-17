# mkab.py OUT SUCC [bad-crc|bad-magic|illegal]: write a made-up A/B block
# (AvbABData, 32 bytes, at offset 0 of OUT) for the tests of uc-pxx-leds.
# Slot A {15, 0 or 7, SUCC}, slot B {14, 0, 1}. SUCC "none" writes zeros.
import struct
import sys
import zlib

out, succ = sys.argv[1], sys.argv[2]
how = sys.argv[3] if len(sys.argv) > 3 else ""
if succ == "none":
    blk = bytes(32)
else:
    s = int(succ)
    a = bytes((15, 0 if s else 7, s, 0))
    if how == "illegal":
        a = bytes((15, 1, 1, 0))                 # successful with tries: illegal
    head = b"\x00AB0" + bytes((1, 0, 0, 0)) + a + bytes((14, 0, 1, 0)) + bytes(12)
    if how == "bad-magic":
        head = b"\x00AB1" + head[4:]
    crc = zlib.crc32(head) & 0xffffffff
    if how == "bad-crc":
        crc ^= 1
    blk = head + struct.pack(">I", crc)
with open(out, "wb") as f:
    f.write(blk + bytes(480))
