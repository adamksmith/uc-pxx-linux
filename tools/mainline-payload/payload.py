#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""The mainline payload (contract v1) of the UC-P10: checks, the boot image
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
  payload.py assemble TEMPLATE RESOURCE OUT
      Put RESOURCE into a copy of TEMPLATE as the "second" part, as
      kernel/mkimage.sh --resource RESOURCE makes it from the same inputs.
  payload.py manifest --version V --pin PIN_FILE --template F --resource F
                      --assembled F --rootfs F --out MANIFEST [--allow-over-cap]
      Check every part and write manifest.json. ASSEMBLED must be the image of
      kernel/mkimage.sh --resource RESOURCE (build.sh makes it); the generator
      assembles the template again by itself and stops when the two differ.

Every refusal exits with status 1 and one line "payload: ...". An assembled
image larger than the cap of the signed 1.0.0.94 vbmeta exits with status 3
(the manifest is written only with --allow-over-cap).

The resource is the stock boot resource of the unit (a vendor file). This
program reads it to compute the assembled image; it never copies it into the
payload. Standard library only. Run with python3 -I.
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
# image_size of the boot hash descriptor of the signed 1.0.0.94 userdebug
# vbmeta (FIRMWARE-ALL37.md). libavb loads only this many bytes of boot_a.
VBMETA_BOOT_CAP = 38029312
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


def cmd_assemble(a):
    tpl, res = read(a[0]), read(a[1])
    check_layout(tpl, "the boot template")
    out = assemble(tpl, res)
    check_layout(out, "the assembled image")
    with open(a[2], "wb") as f:
        f.write(out)


def cmd_manifest(a):
    opts, allow = {}, False
    i = 0
    while i < len(a):
        if a[i] == "--allow-over-cap":
            allow = True
            i += 1
            continue
        if a[i] not in ("--version", "--pin", "--template", "--resource", "--assembled", "--rootfs", "--out") or i + 1 >= len(a):
            raise Refuse("manifest: unknown or incomplete option %s" % a[i])
        if a[i] in opts:
            raise Refuse("manifest: %s given twice" % a[i])
        opts[a[i]] = a[i + 1]
        i += 2
    for k in ("--version", "--pin", "--template", "--resource", "--assembled", "--rootfs", "--out"):
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
    man = {
        "schema": 1,
        "kind": "uc-pxx-mainline",
        "version": version,
        "model": MODEL,
        "kernel": {"rev": pin},
        "token": h["token"],
        "boot_template": {"file": "boot-template.img", "size": len(tpl), "sha256": sha256(tpl)},
        "boot_assembled": {"resource_sha256": RESOURCE_SHA256, "size": len(mine), "sha256": sha256(mine)},
        "rootfs": {"file": "rootfs.ext4", "size": rsize, "sha256": rsha, "label": ROOTFS_LABEL},
        "requires_bootchain": dict(BOOTCHAIN),
        "vbmeta_boot_cap": VBMETA_BOOT_CAP,
    }
    over = len(mine) - VBMETA_BOOT_CAP
    print("boot template %d bytes, sha256 %s, token %s, kernel %s" % (len(tpl), sha256(tpl), h["token"], h["release"]))
    print("boot assembled %d bytes, sha256 %s" % (len(mine), sha256(mine)))
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
            "scan-tar": (1, cmd_scan_tar),
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
