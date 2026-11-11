#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Boot test of the both-slot initramfs in qemu: the slot that U-Boot names
# decides the root partition (MAINLINE-STEP2-DESIGN section 10 L2, review F7).
# It boots the REAL initramfs (the exact cpio that ci/build-kernel.sh builds
# into the kernel Image of the kernel package) with a TEST kernel of the same
# source: the pinned kernel with defconfig + uc-pxx.config, as
# ci/build-kernel.sh makes it, plus CONFIG_MMC_SDHCI_PCI=y, so that the qemu
# machine "virt" has an MMC card (/dev/mmcblk0, the GPT names of the eMMC). The
# property /chosen/u-boot,bootargs of the device tree (what the shim copies
# from U-Boot) is set per case with fdtput. The disk is a GPT with partitions
# named as on the UC-P10; system_a and system_b hold small ext4 file systems
# labeled tsxroot with a marker and a /sbin/init that prints the marker and
# powers off.
#
#   kernel/tests/test-slot-boot-qemu.sh --initramfs CPIO --kernel-src DIR --work DIR
#                                       [--test-image IMAGE] [--template BOOTIMG] [--jobs N]
#
# --initramfs   the cpio (rootfs/build-rootfs.sh initramfs, out/initramfs.cpio)
# --kernel-src  a checkout of the kernel at kernel/KERNEL_REV.lts (read only;
#               the test kernel builds in WORK/kbuild)
# --test-image  a test Image built before (skips the kernel build). Its
#               initramfs must still be CPIO
# --template    the boot template of the payload (or /boot/uc-pxx-lts.img of
#               the kernel package): its initramfs must be CPIO byte for byte
#
# Cases (each its own qemu run, in parallel):
#   a      slot _a, system_a and system_b present  -> the root of system_a
#   b      slot _b                                 -> the root of system_b
#   ram    no u-boot,bootargs (a RAM boot)         -> system_a
#   b-gone slot _b, no partition named system_b (a tsxroot fs elsewhere) -> rescue
#   two    two slot words (_a and _b)              -> rescue
#   bad    slot word _c                            -> rescue
#   b-label slot _b, system_b without the tsxroot label -> rescue
# The test touches no unit. It needs qemu-system-aarch64, fdtput, python3,
# docker (an x86_64 image with mkfs.ext4: UC_PXX_TEST_IMAGE, default
# uc-pxx-datatest:3.24) and, for the kernel build, the tools of
# ci/build-kernel.sh. Run it on the build host.
set -euo pipefail
HERE=$(cd "$(dirname "$0")/../.." && pwd)
CPIO= KSRC= W= TIMG= TPL= JOBS=$(nproc)
while [ $# -gt 0 ]; do
	case $1 in
	--initramfs) CPIO=${2:?}; shift;;
	--kernel-src) KSRC=${2:?}; shift;;
	--work) W=${2:?}; shift;;
	--test-image) TIMG=${2:?}; shift;;
	--template) TPL=${2:?}; shift;;
	--jobs) JOBS=${2:?}; shift;;
	*) sed -n '2,40p' "$0" >&2; exit 2;;
	esac
	shift
done
# Without arguments (the loop of the host tests): nothing to boot
[ -n "$CPIO$KSRC$W$TIMG" ] || { echo "SKIPPED: test-slot-boot-qemu needs --initramfs, --kernel-src and --work (a run by hand on the build host)"; exit 0; }
[ -f "$CPIO" ] && [ -n "$W" ] || { sed -n '16,18p' "$0" >&2; exit 2; }
[ -n "$TIMG" ] || [ -d "$KSRC" ] || { echo "test-slot-boot-qemu: --kernel-src or --test-image is required" >&2; exit 2; }
for t in qemu-system-aarch64 fdtput python3 docker; do command -v $t >/dev/null || { echo "SKIPPED: $t is not installed"; exit 0; }; done
DIMG=${UC_PXX_TEST_IMAGE:-uc-pxx-datatest:3.24}
mkdir -p "$W"; W=$(cd "$W" && pwd); CPIO=$(readlink -f "$CPIO")
N=0 F=0
ok()  { N=$((N + 1)); echo "  ok: $*"; }
bad() { F=$((F + 1)); echo "  FAIL: $*"; }
CSHA=$(sha256sum < "$CPIO" | cut -c1-64)
echo "initramfs $CPIO sha256 $CSHA"

# initramfs_of FILE: the sha256 of the xz-compressed newc cpio in a Linux
# Image or a boot image (the same scan as payload.py initramfs)
initramfs_of() {
	python3 -I - "$1" <<-'EOF'
	import hashlib, lzma, sys
	data = open(sys.argv[1], "rb").read()
	i = data.find(b"\xfd7zXZ\x00")
	while i >= 0:
	    try:
	        out = lzma.LZMADecompressor(format=lzma.FORMAT_XZ).decompress(data[i:])
	        if out[:6] in (b"070701", b"070702"):
	            print(hashlib.sha256(out).hexdigest()); sys.exit(0)
	    except lzma.LZMAError:
	        pass
	    i = data.find(b"\xfd7zXZ\x00", i + 1)
	print("none")
	EOF
}

if [ -n "$TPL" ]; then
	got=$(initramfs_of "$TPL")
	[ "$got" = "$CSHA" ] && ok "the template $TPL holds this initramfs" || bad "the template holds initramfs $got, not $CSHA"
fi

# ---- the test kernel ---------------------------------------------------------
if [ -z "$TIMG" ]; then
	REV=$(grep -v '^#' "$HERE/kernel/KERNEL_REV.lts" | head -n 1 | tr -d ' \n')
	[ "$(git -C "$KSRC" rev-parse HEAD)" = "$REV" ] || { echo "test-slot-boot-qemu: $KSRC is not at the pin $REV" >&2; exit 1; }
	CROSS=${CROSS_COMPILE:-aarch64-linux-gnu-}
	B=$W/kbuild; rm -rf "$B"; mkdir -p "$B"
	M="make -C $KSRC O=$B ARCH=arm64 CROSS_COMPILE=$CROSS KBUILD_BUILD_USER=build KBUILD_BUILD_HOST=uc-pxx-test"
	echo "== test kernel: $REV defconfig + uc-pxx.config + MMC_SDHCI_PCI"
	$M -s defconfig uc-pxx.config
	cp "$CPIO" "$B/initramfs.cpio"
	"$KSRC/scripts/config" --file "$B/.config" --set-str INITRAMFS_SOURCE initramfs.cpio \
		-e RD_XZ -e INITRAMFS_COMPRESSION_XZ -e MMC_SDHCI_PCI
	$M -s olddefconfig
	grep -qx 'CONFIG_MMC_SDHCI_PCI=y' "$B/.config" || { echo "test-slot-boot-qemu: MMC_SDHCI_PCI did not stick" >&2; exit 1; }
	$M -s -j"$JOBS" Image > "$W/kbuild.log" 2>&1 || { tail -20 "$W/kbuild.log"; exit 1; }
	TIMG=$B/arch/arm64/boot/Image
fi
got=$(initramfs_of "$TIMG")
[ "$got" = "$CSHA" ] && ok "the test Image holds this initramfs" || { bad "the test Image holds initramfs $got"; exit 1; }

# ---- the fake roots and the disks --------------------------------------------
# busybox and the musl loader of the initramfs itself run the fake init
R=$W/roots; rm -rf "$R"; mkdir -p "$R"
python3 -I - "$CPIO" "$R/bin" <<-'EOF'
import os, sys
data = open(sys.argv[1], "rb").read(); out = sys.argv[2]; os.makedirs(out, exist_ok=True)
want = {"bin/busybox": "busybox", "lib/ld-musl-aarch64.so.1": "ld-musl-aarch64.so.1"}
off = 0
while off + 110 <= len(data):
    mode = int(data[off + 14:off + 22], 16); fsize = int(data[off + 54:off + 62], 16)
    nsize = int(data[off + 94:off + 102], 16)
    name = data[off + 110:off + 110 + nsize - 1].decode()
    if name == "TRAILER!!!": break
    off = (off + 110 + nsize + 3) & ~3
    n = name[2:] if name.startswith("./") else name
    if n in want and mode & 0o170000 == 0o100000:
        open(os.path.join(out, want[n]), "wb").write(data[off:off + fsize])
    off = (off + fsize + 3) & ~3
for v in want.values():
    if not os.path.exists(os.path.join(out, v)): sys.exit("no %s in the initramfs" % v)
EOF
for id in A B X; do
	d=$R/$id; mkdir -p "$d/bin" "$d/lib" "$d/sbin" "$d/dev" "$d/proc" "$d/sys" "$d/run" "$d/etc"
	cp "$R/bin/busybox" "$d/bin/busybox"; cp "$R/bin/ld-musl-aarch64.so.1" "$d/lib/"
	chmod 755 "$d/bin/busybox" "$d/lib/ld-musl-aarch64.so.1"
	echo "$id" > "$d/slottest-id"
	printf '%s\n' '#!/bin/busybox sh' \
		'/bin/busybox echo "SLOTTEST-ROOT=$(/bin/busybox cat /slottest-id) DEV=$(/bin/busybox awk '"'"'$2 == "/" { print $1 }'"'"' /proc/mounts | /bin/busybox tail -n 1)" > /dev/console' \
		'/bin/busybox sync' '/bin/busybox poweroff -f' > "$d/sbin/init"
	chmod 755 "$d/sbin/init"
done
# mkfs.ext4 -d in the x86_64 test image (no root on the host): A and B are
# tsxroot, X is tsxroot too (it sits in a partition of another name), L has
# another label (B's content)
docker run --rm --network none -v "$R:/r" "$DIMG" sh -c '
	set -e
	for id in A B X; do mkfs.ext4 -q -F -L tsxroot -d /r/$id /r/$id.ext4 24M; done
	mkfs.ext4 -q -F -L notroot -d /r/B /r/L.ext4 24M
	chown '"$(id -u):$(id -g)"' /r/*.ext4'
# mkdisk OUT NAME=FILE...: a 256 MiB GPT (qemu wants a power of 2) with the
# partitions of the eMMC in front (misc, boot_a, boot_b) and 32 MiB slots
mkdisk() {
	python3 -I - "$@" <<-'EOF'
	import os, struct, sys, uuid, zlib
	out = sys.argv[1]; parts = [a.split("=", 1) for a in sys.argv[2:]]
	SIZE = 256 << 20; SEC = 512; NSEC = SIZE // SEC
	start = 2048; ents = []
	for name, f in parts:
	    n = 65536  # 32 MiB each
	    ents.append((name, f, start, start + n - 1)); start += n
	img = bytearray(SIZE)
	lin = uuid.UUID("0fc63daf-8483-4772-8e79-3d69d8477de4").bytes_le
	tbl = bytearray(128 * 128)
	for i, (name, f, s, e) in enumerate(ents):
	    nm = name.encode("utf-16-le").ljust(72, b"\0")
	    tbl[i * 128:(i + 1) * 128] = lin + uuid.uuid5(uuid.NAMESPACE_DNS, "slottest-%d" % i).bytes_le + struct.pack("<QQQ", s, e, 0) + nm
	    if f != "-":
	        d = open(f, "rb").read(); img[s * SEC:s * SEC + len(d)] = d
	def hdr(cur, alt, tstart):
	    h = bytearray(struct.pack("<8sIIIIQQQQ16sQIII", b"EFI PART", 0x10000, 92, 0, 0, cur, alt, 34, NSEC - 34,
	                              uuid.uuid5(uuid.NAMESPACE_DNS, "slottest-disk").bytes_le, tstart, 128, 128, zlib.crc32(tbl)))
	    h[16:20] = struct.pack("<I", zlib.crc32(bytes(h))); return bytes(h)
	mbr = bytearray(512); mbr[446:462] = struct.pack("<BBBBBBBBII", 0, 0, 2, 0, 0xee, 0xff, 0xff, 0xff, 1, NSEC - 1); mbr[510:512] = b"\x55\xaa"
	img[0:512] = mbr; img[SEC:SEC + 92] = hdr(1, NSEC - 1, 2); img[2 * SEC:2 * SEC + len(tbl)] = tbl
	img[(NSEC - 33) * SEC:(NSEC - 33) * SEC + len(tbl)] = tbl; img[(NSEC - 1) * SEC:(NSEC - 1) * SEC + 92] = hdr(NSEC - 1, 1, NSEC - 33)
	open(out, "wb").write(img)
	EOF
}
mkdisk "$W/disk-ab.img" misc=- boot_a=- boot_b=- system_a="$R/A.ext4" system_b="$R/B.ext4" userdata=-
mkdisk "$W/disk-nob.img" misc=- boot_a=- boot_b=- system_a="$R/A.ext4" system_x="$R/X.ext4" userdata=-
mkdisk "$W/disk-label.img" misc=- boot_a=- boot_b=- system_a="$R/A.ext4" system_b="$R/L.ext4" userdata=-

# ---- the device trees and the runs ---------------------------------------------
QM=(qemu-system-aarch64 -M virt -cpu cortex-a53 -smp 2 -m 1024 -nographic -no-reboot)
"${QM[@]}" -machine dumpdtb="$W/virt.dtb" >/dev/null 2>&1
[ -s "$W/virt.dtb" ] || { echo "test-slot-boot-qemu: qemu dumpdtb failed" >&2; exit 1; }
# The blob of dumpdtb has no free space: given back with -dtb as it is, the
# guest prints nothing (measured). fdtput rewrites it with room; the marker
# property is not read by the initramfs.
fdtput -t s "$W/virt.dtb" /chosen uc-pxx,slottest base
UB="console=ttyS2,115200 earlycon=uart8250,mmio32,0xff1a0000 root=PARTUUID=0 init=/init"
# run_case NAME DISK BOOTARGS: BOOTARGS "-" leaves /chosen/u-boot,bootargs out
run_case() {
	local name=$1 disk=$2 ub=$3 dtb=$W/$1.dtb log=$W/$1.log
	cp "$W/virt.dtb" "$dtb"
	[ "$ub" = - ] || fdtput -t s "$dtb" /chosen u-boot,bootargs "$ub"
	cp "$W/$disk" "$W/$name.img"
	timeout -s KILL 300 "${QM[@]}" -kernel "$TIMG" -dtb "$dtb" \
		-append "console=ttyAMA0 uc-pxx.rootwait=8 panic=-1" \
		-device sdhci-pci -device sd-card,drive=sd -drive if=none,id=sd,file="$W/$name.img",format=raw \
		> "$log" 2>&1 &
	local q=$!
	while kill -0 $q 2>/dev/null; do
		if grep -q 'uc-pxx-initramfs: RESCUE:' "$log" 2>/dev/null; then sleep 2; kill -KILL $q 2>/dev/null; break; fi
		sleep 1
	done
	wait $q 2>/dev/null || true
}
declare -A DISK=( [a]=disk-ab.img [b]=disk-ab.img [ram]=disk-ab.img [b-gone]=disk-nob.img [two]=disk-ab.img [bad]=disk-ab.img [b-label]=disk-label.img )
declare -A ARGS=( [a]="$UB androidboot.slot_suffix=_a" [b]="$UB androidboot.slot_suffix=_b" [ram]=-
	[b-gone]="$UB androidboot.slot_suffix=_b" [two]="$UB androidboot.slot_suffix=_a androidboot.slot_suffix=_b"
	[bad]="$UB androidboot.slot_suffix=_c" [b-label]="$UB androidboot.slot_suffix=_b" )
declare -A WANT=( [a]=A [b]=B [ram]=A [b-gone]=rescue [two]=rescue [bad]=rescue [b-label]=rescue )
ORDER="a b ram b-gone two bad b-label"
echo "== qemu runs: $ORDER"
for c in $ORDER; do run_case "$c" "${DISK[$c]}" "${ARGS[$c]}" & done
wait
for c in $ORDER; do
	log=$W/$c.log w=${WANT[$c]}
	got=$(sed -n 's/.*SLOTTEST-ROOT=\([A-Z]\).*/\1/p' "$log" | head -n 1)
	sel=$(sed -n 's/.*uc-pxx-initramfs: \(booted slot .*\)$/\1/p' "$log" | head -n 1 | tr -d '\r')
	resc=$(sed -n 's/.*uc-pxx-initramfs: RESCUE: \(.*\)$/\1/p' "$log" | head -n 1 | tr -d '\r')
	if [ "$w" = rescue ]; then
		if [ -n "$resc" ] && [ -z "$got" ]; then ok "$c: rescue ($resc)"; else bad "$c: expected the rescue, got root '${got:-none}' ($sel)"; fi
	else
		dev=$(sed -n 's/.*SLOTTEST-ROOT=[A-Z] DEV=\([^ ]*\).*/\1/p' "$log" | head -n 1 | tr -d '\r')
		if [ "$got" = "$w" ] && [ -z "$resc" ]; then ok "$c: root $got on $dev ($sel)"; else bad "$c: expected root $w, got '${got:-none}' (rescue '${resc:-none}', $sel)"; fi
	fi
done
echo "test-slot-boot-qemu: $N ok, $F failed (logs in $W/*.log)"
[ "$F" = 0 ]
