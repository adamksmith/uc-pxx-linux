#!/bin/sh
# Host test for the mainline payload (tools/mainline-payload, contract v1 of
# docs/mainline-payload.md) with a made-up kernel Image, device tree, resource
# and rootfs. It checks:
#   - the byte layout of the boot template (kernel/mkimage.sh with an empty
#     resource) and of the assembly: payload.py assemble of the template and a
#     resource gives the same bytes as kernel/mkimage.sh --resource, and only
#     the header fields second_size, second_addr and id change
#   - the refusals of check-template and of the manifest generator: a kernel
#     pin that is not the reviewed one, a release of another kernel, a header
#     name that differs from uc-pxx.id, a template with a second part, a
#     resource that is not the stock one, a rootfs that is not a multiple of
#     512 or has another label, an assembled image that differs
#   - build.sh refuses a checkout whose kernel/KERNEL_REV.lts is not the
#     reviewed pin before it does anything else
# The parts with kernel/mkimage.sh need the cross compiler, mkbootimg, dtc,
# fdtget and fdtput; without them they print SKIPPED. The rest needs python3.
# UC_PXX_RESOURCE=FILE (the stock resource, sha256 290ef405..., a vendor file
# that stays on the build host) adds the manifest of a whole made-up payload.
set -u
HERE=$(cd "$(dirname "$0")/../.." && pwd)
P="python3 -I $HERE/tools/mainline-payload/payload.py"
CROSS=${CROSS_COMPILE:-aarch64-linux-gnu-}
command -v python3 >/dev/null 2>&1 || { echo "SKIPPED: python3 is not installed"; exit 0; }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
N=0 F=0
ok()  { N=$((N + 1)); echo "  ok: $*"; }
bad() { F=$((F + 1)); echo "  FAIL: $*"; }
# refuse WHAT PATTERN CMD...: the command must fail with a line that matches
refuse() {
	what=$1 pat=$2; shift 2
	if out=$("$@" 2>&1); then bad "$what: accepted"; return; fi
	case $out in *$pat*) ok "$what: refused";; *) bad "$what: refused with '$out', expected '$pat'";; esac
}
PIN=$(grep -v '^#' "$HERE/kernel/KERNEL_REV.lts" | head -n 1)
printf '# the reviewed pin\n%s\n' "$PIN" > "$T/pin.ok"
printf 'deadbeef%s\n' "$(echo "$PIN" | cut -c9-)" > "$T/pin.bad"
REL=6.18.54-g$(echo "$PIN" | cut -c1-12)

# a made-up arm64 Image (image_size at 16, "ARM\x64" at 56) with a version banner,
# a resource with the RSCE magic, and a fake ext4 superblock
python3 -I - "$T" "$REL" <<'PY'
import struct, sys
t, rel = sys.argv[1], sys.argv[2]
def image(path, banner):
    n = 3 * 1024 * 1024 + 4096
    h = bytearray(n)
    struct.pack_into("<Q", h, 16, n)
    h[56:60] = b"ARMd"
    b = ("Linux version %s (build@uc-pxx-build) #1 SMP" % banner).encode()
    h[100000:100000 + len(b)] = b
    open(path, "wb").write(h)
image(t + "/Image", rel)
image(t + "/Image.other", "6.18.54-g000000000000")
res = bytearray(b"RSCE" + bytes(4096 + 777))
res[100:110] = b"rk-kernel."
open(t + "/res.img", "wb").write(res)
def ext4(path, size, label, extents=True):
    sb = bytearray(1024)
    struct.pack_into("<I", sb, 4, size // 4096)        # blocks
    struct.pack_into("<I", sb, 24, 2)                  # 4096-byte blocks
    struct.pack_into("<H", sb, 56, 0xEF53)
    struct.pack_into("<I", sb, 96, 0x2c2 if extents else 0x2)
    sb[120:120 + len(label)] = label.encode()
    with open(path, "wb") as f:
        f.write(bytes(1024) + sb)
        f.truncate(size)
ext4(t + "/rootfs.ext4", 8 * 1024 * 1024, "tsxroot")
ext4(t + "/rootfs.label", 8 * 1024 * 1024, "other")
ext4(t + "/rootfs.noext", 8 * 1024 * 1024, "tsxroot", extents=False)
with open(t + "/rootfs.odd", "wb") as f:
    f.write(open(t + "/rootfs.ext4", "rb").read() + b"x")
PY

echo "== payload.py: the pin =="
refuse "check-template with a pin that is not the reviewed one" "the reviewed pin is" $P check-template "$T/Image" "$T/pin.bad"

HAVE=1
for t in "${CROSS}gcc" "${CROSS}ld" "${CROSS}objcopy" mkbootimg fdtget fdtput dtc; do
	command -v "$t" >/dev/null 2>&1 || { HAVE=0; echo "SKIPPED (the kernel/mkimage.sh parts): $t is not installed"; break; }
done
if [ "$HAVE" = 1 ]; then
	dtc -I dts -O dtb -o "$T/p10.dtb" /dev/stdin 2>/dev/null <<'DTS'
/dts-v1/;
/ { #address-cells = <2>; #size-cells = <2>; compatible = "crestron,uc-p10", "rockchip,rk3399";
    chosen { bootargs = "console=ttyS2,115200n8 rdinit=/init"; }; };
DTS
	dtc -I dts -O dtb -o "$T/p8.dtb" /dev/stdin 2>/dev/null <<'DTS'
/dts-v1/;
/ { #address-cells = <2>; #size-cells = <2>; compatible = "crestron,uc-p8", "rockchip,rk3399";
    chosen { bootargs = "console=ttyS2,115200n8 rdinit=/init"; }; };
DTS
	: > "$T/empty"
	mk() { bash "$HERE/kernel/mkimage.sh" "$@" > "$T/mk.log" 2>&1 || { bad "kernel/mkimage.sh $*"; cat "$T/mk.log"; }; }
	mk --resource "$T/empty" --board ucpxx-test0001 "$T/Image" "$T/p10.dtb" "$T/tpl.img"
	mk --resource "$T/res.img" --board ucpxx-test0001 "$T/Image" "$T/p10.dtb" "$T/mk-asm.img"
	mk --resource "$T/empty" --board ucpxx-other01 "$T/Image" "$T/p10.dtb" "$T/tpl.othertoken"
	mk --resource "$T/empty" --board ucpxx-test0001 "$T/Image.other" "$T/p10.dtb" "$T/tpl.otherkernel"
	mk --resource "$T/empty" --board ucpxx-test0001 "$T/Image" "$T/p8.dtb" "$T/tpl.p8"
	mk --resource "$T/res.img" --board ucpxx-test0001 "$T/Image" "$T/p10.dtb" "$T/tpl.second"

	echo "== the boot template =="
	if out=$($P check-template "$T/tpl.img" "$T/pin.ok" 2>&1); then ok "check-template accepts the template"; else bad "check-template: $out"; fi
	echo "$out" | grep -qx 'token=ucpxx-test0001' && ok "the token is the header name" || bad "token: $out"
	echo "$out" | grep -qx "release=$REL" && ok "the kernel release is read from the Image" || bad "release: $out"
	python3 -I - "$T/tpl.img" "$T/Image" <<'PY' && ok "the template layout: header page, shim (device tree at 64 KiB, Image at 2 MiB), ramdisk page, no second" || bad "the template layout"
import struct, sys
img, lin = open(sys.argv[1], "rb").read(), open(sys.argv[2], "rb").read()
ks, ka, rs, ra, ss, sa, ta, page, ver = struct.unpack_from("<9I", img, 8)
assert img[:8] == b"ANDROID!" and ver == 0 and page == 2048
assert ss == 0 and sa == 0 and rs == 20
assert ks == 0x200000 + len(lin)
assert img[2048 + 0x10000:2048 + 0x10004] == b"\xd0\x0d\xfe\xed"
assert img[2048 + 0x200000:2048 + ks] == lin
ram = 2048 * (1 + (ks + 2047) // 2048)
assert len(img) == ram + 2048
PY
	echo "== the assembly =="
	if $P assemble "$T/tpl.img" "$T/res.img" "$T/py-asm.img" 2>"$T/err"; then ok "payload.py assemble runs"; else bad "assemble: $(cat "$T/err")"; fi
	cmp -s "$T/py-asm.img" "$T/mk-asm.img" && ok "payload.py assemble = kernel/mkimage.sh --resource, byte for byte" || bad "the assembly differs from kernel/mkimage.sh --resource"
	python3 -I - "$T/tpl.img" "$T/py-asm.img" "$T/res.img" <<'PY' && ok "the assembly changes only second_size, second_addr and id, and appends the page-padded resource" || bad "the assembly changes more than the second part"
import struct, sys
t, a, r = (open(p, "rb").read() for p in sys.argv[1:])
assert a[:len(t)][:24] == t[:24] and a[32:576] == t[32:576] and a[608:len(t)] == t[608:]
ka = struct.unpack_from("<I", t, 12)[0]
assert struct.unpack_from("<II", a, 24) == (len(r), ka - 0x8000 + 0xf00000)
assert a[576:608] != t[576:608] and a[596:608] == bytes(12)
assert a[len(t):len(t) + len(r)] == r and a[len(t) + len(r):] == bytes(-len(r) % 2048)
assert len(a) % 2048 == 0
PY
	echo "== refusals of check-template =="
	refuse "a template of another kernel release" "the pin is" $P check-template "$T/tpl.otherkernel" "$T/pin.ok"
	refuse "a template that already has a second part" "already has a second part" $P check-template "$T/tpl.second" "$T/pin.ok"
	refuse "a template of the UC-P8 device tree" "not the crestron,uc-p10 device tree" $P check-template "$T/tpl.p8" "$T/pin.ok"
	python3 -I - "$T/tpl.img" "$T/tpl.name" "$T/tpl.trunc" "$T/tpl.id" <<'PY'
import sys
t = bytearray(open(sys.argv[1], "rb").read())
n = bytearray(t); n[48:64] = b"ucpxx-other01".ljust(16, b"\0"); open(sys.argv[2], "wb").write(n)
open(sys.argv[3], "wb").write(t[:-2048])
i = bytearray(t); i[3 * 1024 * 1024] ^= 1; open(sys.argv[4], "wb").write(i)
PY
	refuse "a header name that differs from uc-pxx.id" "header name is ucpxx-other01" $P check-template "$T/tpl.name" "$T/pin.ok"
	refuse "a truncated template" "its header says" $P check-template "$T/tpl.trunc" "$T/pin.ok"
	refuse "a template whose content does not match its id" "id field" $P check-template "$T/tpl.id" "$T/pin.ok"

	echo "== refusals of the manifest generator =="
	# man PIN TEMPLATE RESOURCE ASSEMBLED ROOTFS
	man() { $P manifest --version dev-test --pin "$1" --template "$2" --resource "$3" --assembled "$4" \
		--rootfs "$5" --out "$T/manifest.json"; }
	refuse "the manifest with a pin that is not the reviewed one" "the reviewed pin is" \
		man "$T/pin.bad" "$T/tpl.img" "$T/res.img" "$T/mk-asm.img" "$T/rootfs.ext4"
	refuse "the manifest with a template of another kernel" "the pin is" \
		man "$T/pin.ok" "$T/tpl.otherkernel" "$T/res.img" "$T/mk-asm.img" "$T/rootfs.ext4"
	refuse "the manifest with a resource that is not the stock one" "the stock resource is" \
		man "$T/pin.ok" "$T/tpl.img" "$T/res.img" "$T/mk-asm.img" "$T/rootfs.ext4"
	[ ! -e "$T/manifest.json" ] && ok "a refused manifest is not written" || bad "a refused manifest was written"
	if [ -n "${UC_PXX_RESOURCE:-}" ]; then
		mk --resource "$UC_PXX_RESOURCE" --board ucpxx-test0001 "$T/Image" "$T/p10.dtb" "$T/real-asm.img"
		R=$UC_PXX_RESOURCE
		if out=$(man "$T/pin.ok" "$T/tpl.img" "$R" "$T/real-asm.img" "$T/rootfs.ext4" 2>&1); then ok "the manifest of a made-up payload is written"; else bad "manifest: $out"; fi
		python3 -I - "$T/manifest.json" "$T/tpl.img" "$T/real-asm.img" "$T/rootfs.ext4" "$PIN" <<'PY' && ok "manifest.json has exactly the keys and values of contract v1" || bad "manifest.json is not contract v1"
import hashlib, json, os, sys
m = json.load(open(sys.argv[1]))
sha = lambda p: hashlib.sha256(open(p, "rb").read()).hexdigest()
assert list(m) == ["schema", "kind", "version", "model", "kernel", "token", "boot_template", "boot_assembled",
                   "rootfs", "requires_bootchain", "vbmeta_boot_cap"]
assert m["schema"] == 1 and m["kind"] == "uc-pxx-mainline" and m["model"] == "UC-P10" and m["version"] == "dev-test"
assert m["kernel"] == {"rev": sys.argv[5]} and m["token"] == "ucpxx-test0001"
assert m["boot_template"] == {"file": "boot-template.img", "size": os.path.getsize(sys.argv[2]), "sha256": sha(sys.argv[2])}
assert m["boot_assembled"] == {"resource_sha256": "290ef40577d434d702c3544076dbebd6ddd17e16087eff0e84c92549d67bb363",
                               "size": os.path.getsize(sys.argv[3]), "sha256": sha(sys.argv[3])}
assert m["rootfs"] == {"file": "rootfs.ext4", "size": os.path.getsize(sys.argv[4]), "sha256": sha(sys.argv[4]), "label": "tsxroot"}
assert m["requires_bootchain"] == {
    "version": "1.0.0.94", "build_type": "userdebug",
    "uboot_sha256": "c6e80c1590a44c9abd5756b8553787b84e096563f3726118949c44d1fe8d798c",
    "trust_sha256": "a5ab4d9c5756b5b7f3e0860269207119733b4bc84e8d64600be9671ebb84a562",
    "dtbo_sha256": "83b3e6321c43960bc4215635550a405b297ed965d7fc6ec548bb2b02d9d93629",
    "vbmeta_sha256": "7958c09b4fb6fb3d54a2382682074b4812e92cc1d81ca3183b20f03ff52f5f5c",
    "resource_sha256": "290ef40577d434d702c3544076dbebd6ddd17e16087eff0e84c92549d67bb363"}
assert m["vbmeta_boot_cap"] == 38029312
PY
		rm -f "$T/manifest.json"
		refuse "an assembled image that is not the assembly of the template" "differs from the assembly" \
			man "$T/pin.ok" "$T/tpl.img" "$R" "$T/mk-asm.img" "$T/rootfs.ext4"
		refuse "a rootfs that is not a multiple of 512" "not a multiple of 512" \
			man "$T/pin.ok" "$T/tpl.img" "$R" "$T/real-asm.img" "$T/rootfs.odd"
		refuse "a rootfs with another label" "the label" \
			man "$T/pin.ok" "$T/tpl.img" "$R" "$T/real-asm.img" "$T/rootfs.label"
		refuse "a rootfs that is not ext4" "not ext4" \
			man "$T/pin.ok" "$T/tpl.img" "$R" "$T/real-asm.img" "$T/rootfs.noext"
		[ ! -e "$T/manifest.json" ] && ok "no manifest after these refusals" || bad "a refused manifest was written"
		rm -f "$T/real-asm.img"
	else
		echo "  SKIPPED: the manifest of a whole payload (no UC_PXX_RESOURCE)"
	fi
fi

echo "== build.sh: the kernel pin =="
if command -v git >/dev/null 2>&1; then
	mkdir "$T/repo"
	(cd "$HERE" && git ls-files -z | tar --null -T - -cf -) | tar -C "$T/repo" -xf -
	printf 'deadbeef%s\n' "$(echo "$PIN" | cut -c9-)" > "$T/repo/kernel/KERNEL_REV.lts"
	(cd "$T/repo" && git init -q && git add -A && git -c user.name=t -c user.email=t@t commit -q -m t) >/dev/null 2>&1
	refuse "build.sh with a kernel pin that is not the reviewed one" "not the reviewed kernel" \
		bash "$T/repo/tools/mainline-payload/build.sh" build --snapshot "$T/snap" --resource "$T/res.img" --out "$T/out"
	[ ! -e "$T/out" ] && ok "build.sh made no output" || bad "build.sh made an output"
else
	echo "  SKIPPED: git is not installed"
fi
echo "$N ok, $F failed"
[ "$F" = 0 ]
