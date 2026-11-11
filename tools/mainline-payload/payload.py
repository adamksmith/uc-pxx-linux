#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""The mainline payload (contract v2) of the UC-P10: checks, the boot image
assembly and the manifest. docs/mainline-payload.md tells the contract.

  payload.py check-template TEMPLATE PIN_FILE
      Check the boot template (the boot image of kernel/mkimage.sh with an
      empty resource) and print its facts as KEY=VALUE lines.
  payload.py split TEMPLATE IMAGE_OUT
      Write the Linux Image of the template (the kernel part from 2 MiB on).
  payload.py initramfs TEMPLATE OUT
      Write the initramfs that is built into the Linux Image of the template
      (the xz stream of CONFIG_INITRAMFS_COMPRESSION_XZ) and print its sha256
      and the names of its rescue programs.
  payload.py scan-tar TARGZ
      Refuse a tarball (the rootfs) that holds a Rockchip resource (a file
      that starts with RSCE) or a file with the sha256 of the stock resource.
  payload.py both-slot ROOTFS_TARGZ INITRAMFS_CPIO SOURCE_DIR
      Say whether the payload is a both-slot build of SOURCE_DIR (a copy of
      the uc-pxx-linux commit): each boot-control, slot and data file of the
      rootfs (from the packages) and of the initramfs (from the kernel
      package) must have the bytes of that commit, the list
      /usr/share/uc-pxx/boot-control.sha256 must name /usr/sbin/uc-pxx-slot
      and match the files, and the fstab must name no file system by LABEL=
      or UUID= (it must be the commit's fstab). Modes are checked, and
      uc-pxx-bootctl-inst, a step-2 or DEV-overlay marker, or a doubled cpio
      entry make it "no". Prints one line per file and both_slot=yes or
      both_slot=no. "yes" means "equal to this commit and the two pinned
      binaries", not "reviewed": only the installer's gate pins decide.
      The exit status is 0 either way (build.sh --require-both-slot stops on
      no).
  payload.py assemble TEMPLATE RESOURCE OUT
      Put RESOURCE into a copy of TEMPLATE as the "second" part, as
      kernel/mkimage.sh --resource RESOURCE makes it from the same inputs.
  payload.py manifest --version V --pin PIN_FILE --template F --resource F
                      --assembled F --rootfs F --vbmeta F --vbmeta-patched F
                      --out MANIFEST [--allow-over-cap]
      Check every part and write manifest.json. ASSEMBLED must be the image of
      kernel/mkimage.sh --resource RESOURCE (build.sh makes it); the generator
      assembles the template again by itself and stops when the two differ.
      VBMETA is the signed vbmeta of 1.0.0.94 userdebug, VBMETA_PATCHED the
      output of vbmeta-patch.py patch: the generator checks that the two differ
      only in the image_size field of the boot hash descriptor, which holds
      the new cap, and that the patched file has the pinned sha256.

Every refusal exits with status 1 and one line "payload: ...". An assembled
image larger than the boot cap of the patched vbmeta exits with status 3 (the
manifest is written only with --allow-over-cap).

The resource and the two vbmeta files are vendor files. This program reads
them to compute the assembled image and to check the patch; it never copies
them into the payload: the manifest holds only their sha256 and sizes, and
the installer makes the patched vbmeta again from the keeper's vbmeta_b. Standard library only. Run with python3 -I.
"""
import hashlib
import json
import lzma
import os
import re
import struct
import sys
import tarfile

# The reviewed kernel (docs/kernel.md, ucp10 RULES.md): the only pin that the
# payload accepts. A new pin needs a new review and a change of this line.
REVIEWED_KERNEL_REV = "d02e92631f2810a4a43fb6f09824afb9b0044ee2"
MODEL = "UC-P10"
DT_MODEL = "crestron,uc-p10"
# The stock boot resource of the UC-P10 (docs/boot-control.md "The boot image
# rule"): the only resource that the installer puts into boot_a.
RESOURCE_SHA256 = "290ef40577d434d702c3544076dbebd6ddd17e16087eff0e84c92549d67bb363"
# The boot chain that the mainline slot needs: 1.0.0.94 userdebug (contract v1).
BOOTCHAIN = {
    "version": "1.0.0.94",
    "build_type": "userdebug",
    "uboot_sha256": "c6e80c1590a44c9abd5756b8553787b84e096563f3726118949c44d1fe8d798c",
    "trust_sha256": "a5ab4d9c5756b5b7f3e0860269207119733b4bc84e8d64600be9671ebb84a562",
    "dtbo_sha256": "83b3e6321c43960bc4215635550a405b297ed965d7fc6ec548bb2b02d9d93629",
    "vbmeta_sha256": "7958c09b4fb6fb3d54a2382682074b4812e92cc1d81ca3183b20f03ff52f5f5c",
    "resource_sha256": RESOURCE_SHA256,
}
# Contract v2: vbmeta_a is the signed 1.0.0.94 userdebug vbmeta with only the
# image_size of its boot hash descriptor changed (vbmeta-patch.py). libavb
# loads only image_size bytes of boot_a: the signed value is 38,029,312, the
# patched value is 67,108,864 (the size of boot_a; unit 2's vbmeta_a since
# 2026-10-24). The values are pinned here and in vbmeta-patch.py.
SCHEMA = 2
SIGNED_BOOT_IMAGE_SIZE = 38029312
VBMETA_BOOT_CAP = 67108864
VBMETA_SIZE = 8192
VBMETA_FIELD_OFFSET = 1088
VBMETA_PATCHED_SHA256 = "cebd4d8a68c8861b9801c4d83a14ab3d06f1d85b015a01686fae2d305a69f35e"
ROOTFS_LABEL = "tsxroot"
# kernel/mkimage.sh: header version 0, page 2048, the shim with the device
# tree at 64 KiB and the Linux Image at 2 MiB, mkbootimg default offsets.
PAGE = 2048
SHIM_DTB = 0x10000
SHIM_LINUX = 0x200000
RAMDISK_SIZE = 20          # gzip -9n of an empty file
TOKEN_RE = re.compile(r"^[A-Za-z0-9._-]{1,15}$")
VERSION_RE = re.compile(r"^[A-Za-z0-9._+-]{1,64}$")
FDT_MAGIC = b"\xd0\x0d\xfe\xed"


class Refuse(Exception):
    pass


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def read(path):
    with open(path, "rb") as f:
        return f.read()


def npages(n):
    return (n + PAGE - 1) // PAGE


def read_pin(path):
    for line in open(path, encoding="ascii"):
        line = line.strip()
        if line and not line.startswith("#"):
            return line
    raise Refuse("%s has no revision" % path)


def check_pin(path):
    rev = read_pin(path)
    if not re.match(r"^[0-9a-f]{40}$", rev):
        raise Refuse("the kernel pin %s is not 40 hex digits" % rev)
    if rev != REVIEWED_KERNEL_REV:
        raise Refuse("the kernel pin is %s, the reviewed pin is %s (a new pin needs a review)" % (rev, REVIEWED_KERNEL_REV))
    return rev


# --- the boot image ----------------------------------------------------------

def header(img):
    if len(img) < PAGE or img[:8] != b"ANDROID!":
        raise Refuse("no Android boot image (magic)")
    (ks, ka, rs, ra, ss, sa, ta, page, ver, osv) = struct.unpack_from("<10I", img, 8)
    name = img[48:64]
    h = dict(kernel_size=ks, kernel_addr=ka, ramdisk_size=rs, ramdisk_addr=ra, second_size=ss,
             second_addr=sa, tags_addr=ta, page=page, version=ver, os_version=osv,
             name=name.split(b"\0", 1)[0], name_raw=name, cmdline=img[64:576], id=img[576:608],
             extra=img[608:1632])
    if ver != 0 or page != PAGE:
        raise Refuse("boot image header version %d page %d (kernel/mkimage.sh makes 0 and %d)" % (ver, page, PAGE))
    h["kernel_off"] = PAGE
    h["ramdisk_off"] = PAGE * (1 + npages(ks))
    h["second_off"] = h["ramdisk_off"] + PAGE * npages(rs)
    h["end"] = h["second_off"] + PAGE * npages(ss)
    return h


def image_id(img, h):
    s = hashlib.sha1()
    for off, size in (("kernel_off", "kernel_size"), ("ramdisk_off", "ramdisk_size"), ("second_off", "second_size")):
        s.update(img[h[off]:h[off] + h[size]])
        s.update(struct.pack("<I", h[size]))
    return s.digest() + b"\0" * 12


def fdt_props(dtb, want):
    if len(dtb) < 40 or dtb[:4] != FDT_MAGIC:
        raise Refuse("no device tree")
    total, off_struct, off_strings = struct.unpack_from(">III", dtb, 4)
    size_strings, size_struct = struct.unpack_from(">II", dtb, 32)
    if total > len(dtb) or off_struct + size_struct > total or off_strings + size_strings > total:
        raise Refuse("the device tree header is not plausible")
    path, props, i, end = [], {}, off_struct, off_struct + size_struct
    while i + 4 <= end:
        tok = struct.unpack_from(">I", dtb, i)[0]
        i += 4
        if tok == 1:
            j = dtb.index(b"\0", i)
            path.append(dtb[i:j].decode("ascii", "replace"))
            i = (j + 4) & ~3
        elif tok == 2:
            if not path:
                raise Refuse("the device tree has a bad structure")
            path.pop()
        elif tok == 3:
            ln, nameoff = struct.unpack_from(">II", dtb, i)
            i += 8
            if "/" + "/".join(path[1:]) == want:
                k = off_strings + nameoff
                props[dtb[k:dtb.index(b"\0", k)].decode("ascii", "replace")] = dtb[i:i + ln]
            i = (i + ln + 3) & ~3
        elif tok == 4:
            continue
        elif tok == 9:
            break
        else:
            raise Refuse("the device tree has a bad token")
    return props


def shim_dtb(img, h):
    k = h["kernel_off"]
    d = img[k + SHIM_DTB:k + SHIM_LINUX]
    if d[:4] != FDT_MAGIC:
        raise Refuse("no device tree at 64 KiB in the kernel part")
    return d[:struct.unpack_from(">I", d, 4)[0]]


def check_layout(img, what):
    """The facts that every image of kernel/mkimage.sh has."""
    h = header(img)
    if len(img) != h["end"]:
        raise Refuse("%s has %d bytes, its header says %d" % (what, len(img), h["end"]))
    if image_id(img, h) != h["id"]:
        raise Refuse("the id field of %s does not match its content" % what)
    base = h["kernel_addr"] - 0x8000
    if h["ramdisk_addr"] != base + 0x1000000 or h["tags_addr"] != base + 0x100:
        raise Refuse("%s does not have the default load addresses of mkbootimg" % what)
    if h["ramdisk_size"] != RAMDISK_SIZE:
        raise Refuse("%s: the ramdisk has %d bytes, kernel/mkimage.sh writes %d" % (what, h["ramdisk_size"], RAMDISK_SIZE))
    if h["kernel_size"] <= SHIM_LINUX + 64:
        raise Refuse("%s: the kernel part is too small for the shim" % what)
    linux = img[PAGE + SHIM_LINUX:PAGE + h["kernel_size"]]
    if linux[56:60] != b"ARMd":
        raise Refuse("%s: no arm64 Image at 2 MiB in the kernel part" % what)
    token = h["name"].decode("ascii", "replace")
    if not TOKEN_RE.match(token) or h["name_raw"][len(h["name"]):] != b"\0" * (16 - len(h["name"])):
        raise Refuse("%s has no build token in its header name field" % what)
    chosen = fdt_props(shim_dtb(img, h), "/chosen")
    args = chosen.get("bootargs", b"").rstrip(b"\0").decode("ascii", "replace").split()
    ids = [w[len("uc-pxx.id="):] for w in args if w.startswith("uc-pxx.id=")]
    if ids != [token]:
        raise Refuse("%s: the device tree command line has uc-pxx.id=%s, the header name is %s"
                     % (what, ",".join(ids) or "(none)", token))
    if "linux,initrd-start" in chosen:
        raise Refuse("%s: the device tree still has initrd properties" % what)
    comp = fdt_props(shim_dtb(img, h), "/").get("compatible", b"").split(b"\0")
    if DT_MODEL.encode() not in comp:
        raise Refuse("%s: the device tree is not the %s device tree" % (what, DT_MODEL))
    m = re.search(rb"Linux version (\S+)", linux)
    h["release"] = m.group(1).decode("ascii", "replace") if m else ""
    h["token"] = token
    return h


def check_template(img, pin):
    h = check_layout(img, "the boot template")
    if h["second_size"] != 0 or h["second_addr"] != 0:
        raise Refuse("the boot template already has a second part (%d bytes)" % h["second_size"])
    if not h["release"].endswith("-g" + pin[:12]):
        raise Refuse("the boot template has kernel %s, the pin is %s" % (h["release"] or "(none)", pin))
    return h


def check_resource(res):
    if sha256(res) != RESOURCE_SHA256:
        raise Refuse("the resource has sha256 %s, the stock resource is %s" % (sha256(res), RESOURCE_SHA256))
    if res[:4] != b"RSCE":
        raise Refuse("the resource does not start with RSCE")


def assemble(tpl, res):
    """mkbootimg of the same parts with RES as the second part: the size, the
    second address (base + 0x00f00000) and the id change, and the second part
    follows the ramdisk pages. Nothing else changes."""
    h = header(tpl)
    out = bytearray(tpl[:h["second_off"]])
    struct.pack_into("<II", out, 24, len(res), h["kernel_addr"] - 0x8000 + 0xf00000)
    out += res + b"\0" * (-len(res) % PAGE)
    n = header(bytes(out))
    out[576:608] = image_id(bytes(out), n)
    return bytes(out)


# --- the rootfs ----------------------------------------------------------------

def check_rootfs(path):
    size = os.path.getsize(path)
    if size == 0 or size % 512:
        raise Refuse("rootfs.ext4 has %d bytes, not a multiple of 512" % size)
    with open(path, "rb") as f:
        sb = f.read(2048)[1024:]
    if len(sb) < 1024 or struct.unpack_from("<H", sb, 56)[0] != 0xEF53:
        raise Refuse("rootfs.ext4 has no ext2/3/4 superblock")
    blocks_lo = struct.unpack_from("<I", sb, 4)[0]
    log_bs = struct.unpack_from("<I", sb, 24)[0]
    incompat = struct.unpack_from("<I", sb, 96)[0]
    blocks_hi = struct.unpack_from("<I", sb, 0x150)[0] if incompat & 0x80 else 0
    fs_bytes = (blocks_lo | blocks_hi << 32) * (1024 << log_bs)
    if fs_bytes != size:
        raise Refuse("rootfs.ext4: the file system has %d bytes, the file %d" % (fs_bytes, size))
    if not incompat & 0x40:
        raise Refuse("rootfs.ext4 is not ext4 (no extents)")
    label = sb[120:136].split(b"\0", 1)[0].decode("ascii", "replace")
    if label != ROOTFS_LABEL:
        raise Refuse("rootfs.ext4 has the label %r, not %s" % (label, ROOTFS_LABEL))
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for b in iter(lambda: f.read(1 << 22), b""):
            h.update(b)
    return size, h.hexdigest()


# --- commands --------------------------------------------------------------------

def cmd_check_template(a):
    pin = check_pin(a[1])
    img = read(a[0])
    h = check_template(img, pin)
    print("token=%s" % h["token"])
    print("release=%s" % h["release"])
    print("size=%d" % len(img))
    print("kernel_size=%d" % h["kernel_size"])
    print("linux_size=%d" % (h["kernel_size"] - SHIM_LINUX))
    print("sha256=%s" % sha256(img))


def cmd_split(a):
    img = read(a[0])
    h = header(img)
    with open(a[1], "wb") as f:
        f.write(img[PAGE + SHIM_LINUX:PAGE + h["kernel_size"]])


def cmd_initramfs(a):
    img = read(a[0])
    h = header(img)
    linux = img[PAGE + SHIM_LINUX:PAGE + h["kernel_size"]]
    found = None
    i = linux.find(b"\xfd7zXZ\x00")
    while i >= 0:
        try:
            d = lzma.LZMADecompressor(format=lzma.FORMAT_XZ)
            data = d.decompress(linux[i:])
            if data[:6] in (b"070701", b"070702"):
                found = data
                break
        except lzma.LZMAError:
            pass
        i = linux.find(b"\xfd7zXZ\x00", i + 1)
    if found is None:
        raise Refuse("no xz-compressed newc cpio in the Linux Image")
    names, off = [], 0
    while off + 110 <= len(found) and found[off:off + 6] in (b"070701", b"070702"):
        fsize = int(found[off + 54:off + 62], 16)
        nsize = int(found[off + 94:off + 102], 16)
        name = found[off + 110:off + 110 + nsize - 1].decode("utf-8", "replace")
        if name == "TRAILER!!!":
            break
        names.append(name)
        off = (off + 110 + nsize + 3) & ~3
        off = (off + fsize + 3) & ~3
    with open(a[1], "wb") as f:
        f.write(found)
    print("initramfs_sha256=%s" % sha256(found))
    print("initramfs_size=%d" % len(found))
    print("initramfs_files=%d" % len(names))
    base = {}
    for n in names:
        base.setdefault(n.rsplit("/", 1)[-1], []).append(n.lstrip("."))
    for want in ("init", "rtl8363-init", "uc-pxx-bootctl", "uc-pxx-reboot-syscall", "tsx-splash", "dropbear"):
        print("program_%s=%s" % (want.replace("-", "_"), ",".join(base.get(want, [])) or "missing"))


def cmd_scan_tar(a):
    n = 0
    with tarfile.open(a[0], "r:gz") as tf:
        for m in tf:
            if not m.isreg():
                continue
            n += 1
            f = tf.extractfile(m)
            h = hashlib.sha256()
            head = f.read(4)
            h.update(head)
            for b in iter(lambda: f.read(1 << 20), b""):
                h.update(b)
            if head == b"RSCE" or h.hexdigest() == RESOURCE_SHA256:
                raise Refuse("%s holds a Rockchip resource: %s" % (a[0], m.name))
    print("no Rockchip resource in %d files of %s" % (n, a[0]))


# both-slot: the files of the both-slot boot control (MAINLINE-STEP2-DESIGN
# section 10, MAINLINE-LINUX-INT-2026-11-10 section 7), path in the image ->
# path in the source commit
BOTH_SLOT_ROOTFS = (
    ("usr/sbin/uc-pxx-arm-slot", "rootfs/overlay/usr/sbin/uc-pxx-arm-slot"),
    ("usr/sbin/uc-pxx-flash-boot", "rootfs/overlay/usr/sbin/uc-pxx-flash-boot"),
    ("etc/uc-pxx-mark-boot.sh", "rootfs/overlay/etc/uc-pxx-mark-boot.sh"),
    ("etc/init.d/uc-pxx-boot-ok", "rootfs/overlay/etc/init.d/uc-pxx-boot-ok"),
    ("usr/sbin/uc-pxx-post-update", "rootfs/overlay/usr/sbin/uc-pxx-post-update"),
    ("usr/sbin/uc-pxx-reboot", "rootfs/overlay/usr/sbin/uc-pxx-reboot"),
    ("usr/sbin/uc-pxx-slot", "rootfs/overlay/usr/sbin/uc-pxx-slot"),
    ("usr/local/lib/tsx/board.sh", "rootfs/overlay/usr/local/lib/tsx/board.sh"),
    ("etc/init.d/uc-pxx-lvm", "rootfs/overlay/etc/init.d/uc-pxx-lvm"),
    ("usr/local/sbin/uc-pxx-firmware", "rootfs/overlay/usr/local/sbin/uc-pxx-firmware"),
    ("usr/sbin/uc-pxx-data-migrate", "rootfs/overlay/usr/sbin/uc-pxx-data-migrate"),
    ("usr/sbin/uc-pxx-data-release", "rootfs/overlay/usr/sbin/uc-pxx-data-release"),
)
BOTH_SLOT_INITRAMFS = (
    ("init", "rootfs/initramfs/overlay/init"),
    ("etc/init.d/rcS", "rootfs/initramfs/overlay/etc/init.d/rcS"),
    ("usr/sbin/uc-pxx-findfs", "rootfs/initramfs/overlay/usr/sbin/uc-pxx-findfs"),
    ("usr/sbin/uc-pxx-install-rootfs", "rootfs/initramfs/overlay/usr/sbin/uc-pxx-install-rootfs"),
    ("usr/sbin/tsx-data-backup", "rootfs/initramfs/overlay/usr/sbin/tsx-data-backup"),
    ("usr/sbin/uc-pxx-rescue-help", "rootfs/initramfs/overlay/usr/sbin/uc-pxx-rescue-help"),
    ("usr/sbin/uc-pxx-slot", "rootfs/overlay/usr/sbin/uc-pxx-slot"),
    ("usr/sbin/uc-pxx-reboot", "rootfs/overlay/usr/sbin/uc-pxx-reboot"),
)


# The two binaries of uc-pxx-boot-tools 0.2.0 that are not in this repository:
# uc-pxx-bootctl (built from tools/uc-pxx-bootctl/uc-pxx-bootctl.c, the pin of
# the recipe; NOT yet in the safety rules) and uc-pxx-update-boot (tsx-aports,
# the RULES pin). The exact list of boot-control.sha256 in that package.
BOTH_SLOT_BOOTCTL_SHA256 = "11c2afcd0272f9c989f9825074186a2341d0a33a34e0fe9ebf92cf0081f9efa7"
UPDATE_BOOT_SHA256 = "4de04b78b8a48a4cf4d79f22f18f2f69a6932a36398e4ba6ec0ac175483b3703"
BOTH_SLOT_LIST = ("/usr/sbin/uc-pxx-bootctl", "/etc/uc-pxx-mark-boot.sh", "/etc/init.d/uc-pxx-boot-ok",
                  "/usr/sbin/uc-pxx-flash-boot", "/usr/sbin/uc-pxx-arm-slot", "/usr/sbin/uc-pxx-update-boot",
                  "/usr/sbin/uc-pxx-post-update", "/usr/sbin/uc-pxx-slot")
# files that are sourced, not run (mode 0644); every other checked file is 0755
SOURCED = ("usr/local/lib/tsx/board.sh",)


def cpio_entries(data):
    """The entries of a newc cpio: a list of (name without ./, mode, bytes)."""
    out, off = [], 0
    while off + 110 <= len(data) and data[off:off + 6] in (b"070701", b"070702"):
        mode = int(data[off + 14:off + 22], 16)
        fsize = int(data[off + 54:off + 62], 16)
        nsize = int(data[off + 94:off + 102], 16)
        name = data[off + 110:off + 110 + nsize - 1].decode("utf-8", "replace")
        if name == "TRAILER!!!":
            break
        off = (off + 110 + nsize + 3) & ~3
        # "./init", "/init" and "init" are one path for the kernel
        out.append((re.sub(r"^(\./|/)+", "", name), mode, data[off:off + fsize]))
        off = (off + fsize + 3) & ~3
    return out


def cpio_files(data):
    """The regular files of a newc cpio: name (without ./) -> bytes (the last entry wins, as in the kernel)."""
    return {n: b for n, m, b in cpio_entries(data) if m & 0o170000 == 0o100000}


def cmd_both_slot(a):
    """both_slot=yes means: the files are the bytes (and modes) of this commit and
    of the two pinned binaries. It is not a review: only the gate pins decide."""
    want = set(p for p, _ in BOTH_SLOT_ROOTFS) | {"usr/share/uc-pxx/boot-control.sha256", "etc/fstab",
                                                    "usr/sbin/uc-pxx-bootctl", "usr/sbin/uc-pxx-update-boot"}
    rootfs, rmode, bad = {}, {}, []
    with tarfile.open(a[0], "r:gz") as tf:
        for m in tf:
            n = re.sub(r"^(\./|/)+", "", m.name).rstrip("/")
            base = n.rsplit("/", 1)[-1]
            if base.startswith("uc-pxx-bootctl-inst") or n in ("usr/libexec/uc-pxx-step2", "etc/tsx/dev-overlay",
                                                               "etc/tsx/step2-bootctl-inst"):
                bad.append("rootfs /%s present (uc-pxx-bootctl-inst, a step-2 or a DEV-overlay build)" % n)
            if n in want:
                if not m.isreg():
                    bad.append("rootfs /%s is not a regular file" % n)
                    continue
                rootfs[n] = tf.extractfile(m).read()
                rmode[n] = (m.mode & 0o7777, m.uid, m.gid)
    entries = cpio_entries(read(a[1]))
    seen = {}
    for n, m, b in entries:
        if n in seen:
            bad.append("initramfs /%s is in the cpio twice" % n)
        seen[n] = m
    initramfs = cpio_files(read(a[1]))

    def want_mode(where, img, got):
        exp = 0o644 if img in SOURCED else 0o755
        if where == "rootfs":
            mode, uid, gid = got
            ok = mode == exp and uid == 0 and gid == 0
            shown = "%o %d:%d" % (mode, uid, gid)
        else:
            ok = got & 0o7777 == exp
            shown = "%o" % (got & 0o7777)
        if not ok:
            bad.append("%s /%s has mode %s, not %o root" % (where, img, shown, exp))

    def compare(where, files, table, modes):
        for img, src in table:
            ref = sha256(read(os.path.join(a[2], src)))
            if img not in files:
                print("%s /%s missing (the commit has %s)" % (where, img, ref))
                bad.append("%s /%s missing" % (where, img))
                continue
            got = sha256(files[img])
            if got == ref:
                print("%s /%s %s ok" % (where, img, got))
            else:
                print("%s /%s %s DIFFERS (the commit has %s)" % (where, img, got, ref))
                bad.append("%s /%s differs" % (where, img))
            want_mode(where, img, modes[img])
    compare("rootfs", rootfs, BOTH_SLOT_ROOTFS, rmode)
    compare("initramfs", initramfs, BOTH_SLOT_INITRAMFS, seen)
    for img, pin in (("usr/sbin/uc-pxx-bootctl", BOTH_SLOT_BOOTCTL_SHA256), ("usr/sbin/uc-pxx-update-boot", UPDATE_BOOT_SHA256)):
        if img not in rootfs:
            bad.append("rootfs /%s missing" % img)
            continue
        got = sha256(rootfs[img])
        print("rootfs /%s %s %s" % (img, got, "ok (the pin)" if got == pin else "DIFFERS (the pin is %s)" % pin))
        if got != pin:
            bad.append("rootfs /%s is not the pinned %s" % (img, pin))
        want_mode("rootfs", img, rmode[img])
    lst = rootfs.get("usr/share/uc-pxx/boot-control.sha256")
    if lst is None:
        bad.append("no /usr/share/uc-pxx/boot-control.sha256")
    else:
        names = []
        for line in lst.decode("ascii", "replace").splitlines():
            f = line.split()
            if len(f) != 2 or not re.fullmatch("[0-9a-f]{64}", f[0]) or not f[1].startswith("/"):
                bad.append("boot-control.sha256: a bad line %r" % line)
                continue
            names.append(f[1])
            got = rootfs.get(f[1][1:])
            if got is None:
                bad.append("boot-control.sha256: %s is not a checked file of the image" % f[1])
            elif sha256(got) != f[0]:
                bad.append("boot-control.sha256: %s is not the listed %s" % (f[1], f[0]))
        print("boot-control.sha256: %d files: %s" % (len(names), " ".join(names)))
        if sorted(names) != sorted(BOTH_SLOT_LIST) or len(set(names)) != len(names):
            bad.append("boot-control.sha256 does not list exactly the %d files of the both-slot boot control" % len(BOTH_SLOT_LIST))
    ref = read(os.path.join(a[2], "rootfs/overlay/etc/fstab"))
    if rootfs.get("etc/fstab") != ref:
        bad.append("the fstab is not the commit's (%s): a root or /data line by label, UUID or path is not both-slot"
                   % ("missing" if "etc/fstab" not in rootfs else sha256(rootfs["etc/fstab"])))
    else:
        print("rootfs /etc/fstab %s ok" % sha256(ref))
    for b in bad:
        print("not both-slot: %s" % b)
    print("both_slot=%s" % ("no" if bad else "yes"))


def cmd_assemble(a):
    tpl, res = read(a[0]), read(a[1])
    check_layout(tpl, "the boot template")
    out = assemble(tpl, res)
    check_layout(out, "the assembled image")
    with open(a[2], "wb") as f:
        f.write(out)


MANIFEST_OPTS = ("--version", "--pin", "--template", "--resource", "--assembled", "--rootfs", "--vbmeta",
                 "--vbmeta-patched", "--out")


def check_vbmeta_patch(signed, patched):
    """The patched vbmeta of contract v2: the pinned signed file with only the
    8-byte image_size field of the boot hash descriptor changed to the cap."""
    if len(signed) != VBMETA_SIZE or sha256(signed) != BOOTCHAIN["vbmeta_sha256"]:
        raise Refuse("--vbmeta is %d bytes sha256 %s, not the signed 1.0.0.94 userdebug vbmeta %s" % (
            len(signed), sha256(signed), BOOTCHAIN["vbmeta_sha256"]))
    if len(patched) != VBMETA_SIZE or sha256(patched) != VBMETA_PATCHED_SHA256:
        raise Refuse("--vbmeta-patched is %d bytes sha256 %s, not the pinned patched vbmeta %s" % (
            len(patched), sha256(patched), VBMETA_PATCHED_SHA256))
    o = VBMETA_FIELD_OFFSET
    diff = [i for i in range(VBMETA_SIZE) if signed[i] != patched[i]]
    if not diff or any(i < o or i >= o + 8 for i in diff):
        raise Refuse("the patched vbmeta differs from the signed one outside bytes %d-%d" % (o, o + 7))
    old, new = struct.unpack_from(">Q", signed, o)[0], struct.unpack_from(">Q", patched, o)[0]
    if old != SIGNED_BOOT_IMAGE_SIZE or new != VBMETA_BOOT_CAP:
        raise Refuse("the image_size field holds %d -> %d, not %d -> %d" % (old, new, SIGNED_BOOT_IMAGE_SIZE, VBMETA_BOOT_CAP))


def cmd_manifest(a):
    opts, allow = {}, False
    i = 0
    while i < len(a):
        if a[i] == "--allow-over-cap":
            allow = True
            i += 1
            continue
        if a[i] not in MANIFEST_OPTS or i + 1 >= len(a):
            raise Refuse("manifest: unknown or incomplete option %s" % a[i])
        if a[i] in opts:
            raise Refuse("manifest: %s given twice" % a[i])
        opts[a[i]] = a[i + 1]
        i += 2
    for k in MANIFEST_OPTS:
        if k not in opts:
            raise Refuse("manifest: %s is required" % k)
    version = opts["--version"]
    if not VERSION_RE.match(version):
        raise Refuse("manifest: the version %r has a character outside [A-Za-z0-9._+-] or is too long" % version)
    pin = check_pin(opts["--pin"])
    tpl = read(opts["--template"])
    h = check_template(tpl, pin)
    res = read(opts["--resource"])
    check_resource(res)
    mine = assemble(tpl, res)
    theirs = read(opts["--assembled"])
    if mine != theirs:
        raise Refuse("the image of kernel/mkimage.sh --resource differs from the assembly of the template "
                     "(%s, %s)" % (sha256(theirs), sha256(mine)))
    n = check_layout(mine, "the assembled image")
    if n["token"] != h["token"] or mine[n["second_off"]:n["second_off"] + n["second_size"]] != res:
        raise Refuse("the assembled image does not carry the token and the resource")
    rsize, rsha = check_rootfs(opts["--rootfs"])
    vsigned, vpatched = read(opts["--vbmeta"]), read(opts["--vbmeta-patched"])
    check_vbmeta_patch(vsigned, vpatched)
    man = {
        "schema": SCHEMA,
        "kind": "uc-pxx-mainline",
        "version": version,
        "model": MODEL,
        "kernel": {"rev": pin},
        "token": h["token"],
        "boot_template": {"file": "boot-template.img", "size": len(tpl), "sha256": sha256(tpl)},
        "boot_assembled": {"resource_sha256": RESOURCE_SHA256, "size": len(mine), "sha256": sha256(mine)},
        "rootfs": {"file": "rootfs.ext4", "size": rsize, "sha256": rsha, "label": ROOTFS_LABEL},
        "requires_bootchain": dict(BOOTCHAIN),
        "vbmeta_patched": {"source_sha256": BOOTCHAIN["vbmeta_sha256"], "size": VBMETA_SIZE,
                           "sha256": VBMETA_PATCHED_SHA256, "field_offset": VBMETA_FIELD_OFFSET,
                           "boot_image_size": VBMETA_BOOT_CAP},
        "vbmeta_boot_cap": VBMETA_BOOT_CAP,
    }
    over = len(mine) - VBMETA_BOOT_CAP
    print("boot template %d bytes, sha256 %s, token %s, kernel %s" % (len(tpl), sha256(tpl), h["token"], h["release"]))
    print("boot assembled %d bytes, sha256 %s" % (len(mine), sha256(mine)))
    print("vbmeta patched sha256 %s (boot image_size %d -> %d at byte %d)" % (VBMETA_PATCHED_SHA256,
          SIGNED_BOOT_IMAGE_SIZE, VBMETA_BOOT_CAP, VBMETA_FIELD_OFFSET))
    print("vbmeta boot cap %d bytes: %s" % (VBMETA_BOOT_CAP,
          "fits, %d bytes to spare" % -over if over <= 0 else "OVER THE CAP by %d bytes" % over))
    print("rootfs %d bytes, sha256 %s" % (rsize, rsha))
    if over > 0 and not allow:
        print("payload: the assembled boot image is %d bytes over the vbmeta boot cap: no manifest" % over, file=sys.stderr)
        return 3
    with open(opts["--out"], "w", encoding="ascii") as f:
        json.dump(man, f, indent=2)
        f.write("\n")
    return 3 if over > 0 else 0


def main(argv):
    cmds = {"check-template": (2, cmd_check_template), "split": (2, cmd_split), "initramfs": (2, cmd_initramfs),
            "scan-tar": (1, cmd_scan_tar), "both-slot": (3, cmd_both_slot),
            "assemble": (3, cmd_assemble), "manifest": (None, cmd_manifest)}
    if not argv or argv[0] not in cmds:
        sys.stderr.write(__doc__.split("Every refusal")[0])
        return 2
    n, fn = cmds[argv[0]]
    if n is not None and len(argv) - 1 != n:
        sys.stderr.write("payload: %s takes %d arguments\n" % (argv[0], n))
        return 2
    try:
        return fn(argv[1:]) or 0
    except Refuse as e:
        print("payload: %s" % e, file=sys.stderr)
        return 1
    except (OSError, ValueError, struct.error) as e:
        print("payload: %s" % e, file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
