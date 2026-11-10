#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""The patched vbmeta of the mainline slot (payload contract v2).

  vbmeta-patch.py patch SIGNED OUT
      Read SIGNED, the signed vbmeta of 1.0.0.94 userdebug (8192 bytes,
      sha256 7958c09b...), and write OUT: the same bytes with only the
      image_size of the boot hash descriptor changed from 38,029,312 to
      67,108,864 (the size of boot_a). Print the facts as KEY=VALUE lines.
  vbmeta-patch.py check SIGNED PATCHED
      Make the patch again from SIGNED and refuse unless PATCHED is the same,
      byte for byte.

Why: libavb loads only image_size bytes of boot_a, and U-Boot starts that
buffer. The signed value is smaller than the mainline boot image. Unit 2 has
booted mainline from slot A with this change (image_size 67,108,864 in its
vbmeta_a) since 2026-10-24 (ucp10/docs/mainline-slotA-bringup-2026-10-24.md,
v11). The change breaks the signature of the vbmeta. That adds no new
dependency: the boot hash of a mainline image never matches the signed
digest, so a mainline slot starts only on an unlocked unit (orange) in any
case. On a locked unit the slot fails verification and the keeper starts.

The program parses the AVB structures (the vbmeta header, the auxiliary
block, every descriptor), finds exactly one hash descriptor with the
partition name "boot", and changes only its 8-byte image_size field. It
checks that the input is the pinned signed vbmeta (sha256, and the
header hash over the header and the auxiliary block), that the output
differs from the input only inside that field, that the field now holds the
new value, and that the output has the pinned sha256. Same input, same
output: there is no other input.

The signed vbmeta is a vendor file: it stays on the build host. Every
refusal exits with status 1 and one line "vbmeta-patch: ...". Standard
library only. Run with python3 -I.
"""
import hashlib
import struct
import sys

# The signed vbmeta of 1.0.0.94 userdebug (manifest-1.0.0.94-userdebug.json
# of uc-pxx-installer: the vbmeta image, 8192 bytes).
SIGNED_SHA256 = "7958c09b4fb6fb3d54a2382682074b4812e92cc1d81ca3183b20f03ff52f5f5c"
SIGNED_SIZE = 8192
# The boot hash descriptor of that vbmeta.
BOOT_PARTITION = b"boot"
OLD_IMAGE_SIZE = 38029312
# The new image_size: the size of boot_a (64 MiB), the value of unit 2's
# vbmeta_a since 2026-10-24.
NEW_IMAGE_SIZE = 67108864
# Where the field is in the signed file (derived by the parser below; pinned
# so that a different layout is refused, not followed).
FIELD_OFFSET = 1088
# The sha256 of the output for the pinned input.
PATCHED_SHA256 = "cebd4d8a68c8861b9801c4d83a14ab3d06f1d85b015a01686fae2d305a69f35e"

HEADER_SIZE = 256
TAG_HASH = 2
KNOWN_TAGS = {0: "property", 1: "hashtree", 2: "hash", 3: "kernel_cmdline", 4: "chain_partition"}
HASH_FIXED = 116          # AvbHashDescriptor without its 16-byte tag/length header


class Refuse(Exception):
    pass


def u32(b, o):
    return struct.unpack_from(">I", b, o)[0]


def u64(b, o):
    return struct.unpack_from(">Q", b, o)[0]


def parse(img):
    """The header facts and the list of descriptors (tag, file offset, length)."""
    if len(img) < HEADER_SIZE or img[:4] != b"AVB0":
        raise Refuse("no AVB0 vbmeta header")
    major, minor = u32(img, 4), u32(img, 8)
    if (major, minor) != (1, 0):
        raise Refuse("vbmeta needs libavb %d.%d, not 1.0" % (major, minor))
    auth, aux = u64(img, 12), u64(img, 20)
    alg = u32(img, 28)
    hash_off, hash_size = u64(img, 32), u64(img, 40)
    desc_off, desc_size = u64(img, 96), u64(img, 104)
    if auth % 64 or aux % 64 or HEADER_SIZE + auth + aux > len(img):
        raise Refuse("the authentication and auxiliary block sizes %d/%d do not fit %d bytes" % (auth, aux, len(img)))
    if alg != 2 or hash_size != 32 or hash_off + 32 > auth:
        raise Refuse("algorithm %d with hash %d+%d: not SHA256_RSA4096" % (alg, hash_off, hash_size))
    if desc_off + desc_size > aux:
        raise Refuse("the descriptors are outside the auxiliary block")
    aux_start = HEADER_SIZE + auth
    descs = []
    pos, end = aux_start + desc_off, aux_start + desc_off + desc_size
    while pos < end:
        if end - pos < 16:
            raise Refuse("a descriptor header is cut at %d" % pos)
        tag, nbf = u64(img, pos), u64(img, pos + 8)
        if tag not in KNOWN_TAGS or nbf % 8 or pos + 16 + nbf > end:
            raise Refuse("descriptor at %d: tag %d, %d bytes" % (pos, tag, nbf))
        descs.append((tag, pos, 16 + nbf))
        pos += 16 + nbf
    return {"auth": auth, "aux": aux, "hash_off": hash_off, "aux_start": aux_start}, descs


def header_hash_ok(img, h):
    """The hash in the authentication block over the header and the auxiliary block."""
    want = img[HEADER_SIZE + h["hash_off"]:HEADER_SIZE + h["hash_off"] + 32]
    got = hashlib.sha256(img[:HEADER_SIZE] + img[h["aux_start"]:h["aux_start"] + h["aux"]]).digest()
    return want == got


def boot_field(img, descs):
    """The file offset of the image_size field of the one hash descriptor of boot."""
    found = []
    for tag, pos, ln in descs:
        if tag != TAG_HASH:
            continue
        body = pos + 16
        if ln - 16 < HASH_FIXED:
            raise Refuse("hash descriptor at %d is cut" % pos)
        nl, sl, dl = u32(img, body + 40), u32(img, body + 44), u32(img, body + 48)
        if HASH_FIXED + nl + sl + dl > ln - 16:
            raise Refuse("hash descriptor at %d: its fields do not fit" % pos)
        name = img[body + HASH_FIXED:body + HASH_FIXED + nl]
        if name == BOOT_PARTITION:
            found.append(body)        # image_size is the first field of the body
    if len(found) != 1:
        raise Refuse("%d hash descriptors of boot, not exactly 1" % len(found))
    return found[0]


def make(signed):
    if len(signed) != SIGNED_SIZE or hashlib.sha256(signed).hexdigest() != SIGNED_SHA256:
        raise Refuse("the input is %d bytes sha256 %s, not the signed 1.0.0.94 userdebug vbmeta %s (%d bytes)" % (
            len(signed), hashlib.sha256(signed).hexdigest(), SIGNED_SHA256, SIGNED_SIZE))
    h, descs = parse(signed)
    if not header_hash_ok(signed, h):
        raise Refuse("the header hash of the input does not match its header and auxiliary block")
    off = boot_field(signed, descs)
    if off != FIELD_OFFSET:
        raise Refuse("the boot image_size field is at %d, not at the pinned %d" % (off, FIELD_OFFSET))
    old = u64(signed, off)
    if old != OLD_IMAGE_SIZE:
        raise Refuse("the boot image_size is %d, not %d" % (old, OLD_IMAGE_SIZE))
    out = bytearray(signed)
    struct.pack_into(">Q", out, off, NEW_IMAGE_SIZE)
    out = bytes(out)
    # the proof: the same length, a difference only inside the field, the new value
    diff = [i for i in range(len(out)) if out[i] != signed[i]]
    if len(out) != len(signed) or not diff or any(i < off or i >= off + 8 for i in diff):
        raise Refuse("the output differs outside the image_size field: %s" % diff[:16])
    h2, descs2 = parse(out)
    if descs2 != descs or boot_field(out, descs2) != off or u64(out, off) != NEW_IMAGE_SIZE:
        raise Refuse("the output does not parse to the same descriptors with the new image_size")
    if header_hash_ok(out, h2):
        raise Refuse("the header hash still matches: the field is not covered by it")
    sha = hashlib.sha256(out).hexdigest()
    if sha != PATCHED_SHA256:
        raise Refuse("the output has sha256 %s, not the pinned %s" % (sha, PATCHED_SHA256))
    return out, {"field_offset": off, "old_image_size": old, "new_image_size": NEW_IMAGE_SIZE,
                 "changed_bytes": ",".join(str(i) for i in diff), "signed_sha256": SIGNED_SHA256,
                 "patched_sha256": sha, "size": len(out)}


def main(argv):
    try:
        if len(argv) == 3 and argv[0] == "patch":
            with open(argv[1], "rb") as f:
                out, facts = make(f.read())
            with open(argv[2], "wb") as f:
                f.write(out)
        elif len(argv) == 3 and argv[0] == "check":
            with open(argv[1], "rb") as f:
                out, facts = make(f.read())
            with open(argv[2], "rb") as f:
                if f.read() != out:
                    raise Refuse("%s is not the patch of %s" % (argv[2], argv[1]))
        else:
            sys.stderr.write(__doc__.split("Why:")[0])
            return 2
    except Refuse as e:
        print("vbmeta-patch: %s" % e, file=sys.stderr)
        return 1
    except (OSError, struct.error) as e:
        print("vbmeta-patch: %s" % e, file=sys.stderr)
        return 1
    for k in ("signed_sha256", "size", "field_offset", "old_image_size", "new_image_size", "changed_bytes",
              "patched_sha256"):
        print("%s=%s" % (k, facts[k]))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
