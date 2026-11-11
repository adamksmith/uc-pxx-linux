#!/bin/bash
# Build the kernel of the UC-P10 and UC-P8 on a plain x86 Linux host, with the aarch64
# cross compiler. It needs no docker and no hardware.
#
#   ci/build-kernel.sh --flavor lts --initramfs FILE [--src DIR] [--out DIR] [--jobs N]
#
# The script reads the pinned revision from kernel/KERNEL_REV.<flavor>. It
# gets that revision from KERNEL_REPO (default
# https://github.com/tsx-mainline/linux) when --src has no checkout of it.
# It builds in <src>/../build-<flavor> and writes these files to --out
# (default <src>/../out-<flavor>):
#   Image (not compressed, with the initramfs built in), the device trees
#   rk3399-crestron-ucp10.dtb and rk3399-crestron-ucp8.dtb, kernel.release,
#   kernel.commit, modules-<release>.tar.gz (only when the kernel has
#   modules), sha256sums.txt
# kernel/mkimage.sh makes the boot image from Image and one device tree. The
# device tree belongs to the model, so make one boot image for each model.
#
# --initramfs FILE is required. The config fragment uc-pxx.config does not
# name an initramfs. The script copies the cpio archive FILE into the build
# folder and sets CONFIG_INITRAMFS_SOURCE to the relative name of the copy,
# and CONFIG_INITRAMFS_COMPRESSION_XZ=y. The kernel keeps its config in the
# Image (CONFIG_IKCONFIG), so the relative name keeps the paths of the build
# machine out of the Image. The kernel compresses the archive with xz, so FILE
# must not be compressed.
#
# Host packages: gcc-aarch64-linux-gnu, make, bc, bison, flex, libssl-dev,
# libelf-dev, kmod, zstd, xz-utils, git.
# Env: CROSS_COMPILE (default aarch64-linux-gnu-), KERNEL_REPO, DTB_NAMES (the
# device trees to build, separated by spaces), KBUILD_BUILD_TIMESTAMP (default:
# the commit time of the pinned revision, so the version banner and the Image
# do not depend on the build time).
#
# A reproducible build: the release is always <version>-g<12 digits of the
# pin> (the script stops when the checkout would give another name, for
# example "-00022-g..." from tags that git describe finds: use a checkout
# without tags; the fetch below takes none), the build timestamp is the
# commit's, and the modules tarball is packed in name order with fixed times.
# The output has build-info.txt: the release, the timestamp, the sha256 of the
# initramfs and the versions of the compiler and the linker.
set -euo pipefail
HERE=$(cd "$(dirname "$0")/.." && pwd)
FLAVOR= SRC= OUT= INITRAMFS= JOBS=$(nproc)
usage() { sed -n '2,30p' "$0" >&2; exit 2; }
while [ $# -gt 0 ]; do
	case $1 in
	--flavor) FLAVOR=${2:?}; shift;;
	--src) SRC=${2:?}; shift;;
	--out) OUT=${2:?}; shift;;
	--jobs) JOBS=${2:?}; shift;;
	--initramfs) INITRAMFS=${2:?}; shift;;
	-h|--help) usage;;
	*) usage;;
	esac
	shift
done
case $FLAVOR in lts) ;; *) usage;; esac
[ -n "$INITRAMFS" ] || { echo "build-kernel: --initramfs FILE is required" >&2; usage; }
[ -f "$INITRAMFS" ] || { echo "build-kernel: no initramfs $INITRAMFS" >&2; exit 1; }
REPO_URL=${KERNEL_REPO:-https://github.com/tsx-mainline/linux}
CROSS=${CROSS_COMPILE:-aarch64-linux-gnu-}
DTBS=${DTB_NAMES:-rk3399-crestron-ucp10.dtb rk3399-crestron-ucp8.dtb}
REV=$(grep -v '^#' "$HERE/kernel/KERNEL_REV.$FLAVOR" | head -n 1 | tr -d ' \n')
[ ${#REV} = 40 ] || { echo "build-kernel: kernel/KERNEL_REV.$FLAVOR has no 40 digit revision" >&2; exit 1; }
case $REV in *[!0]*) ;; *) echo "build-kernel: kernel/KERNEL_REV.$FLAVOR is still the placeholder" >&2; exit 1;; esac
SRC=${SRC:-$HERE/../linux-uc-pxx-$FLAVOR}
BUILD=$(dirname "$SRC")/build-$FLAVOR
OUT=${OUT:-$(dirname "$SRC")/out-$FLAVOR}
command -v "${CROSS}gcc" >/dev/null || { echo "build-kernel: no ${CROSS}gcc" >&2; exit 1; }

echo "== source: $REPO_URL $REV -> $SRC"
if [ "$(git -C "$SRC" rev-parse HEAD 2>/dev/null || true)" != "$REV" ]; then
	[ -d "$SRC/.git" ] || { mkdir -p "$SRC"; git -C "$SRC" init -q; git -C "$SRC" remote add origin "$REPO_URL"; }
	# A blobless fetch keeps the history and loads only the files of the
	# checkout. No tags: with a tag in reach, setlocalversion would add the
	# commit count to the release (6.18.54-00022-g...), not the name of the
	# packages (6.18.54-g<12 digits>).
	git -C "$SRC" fetch -q --filter=blob:none --no-tags origin "$REV"
	git -C "$SRC" checkout -q --force "$REV"
fi
[ "$(git -C "$SRC" rev-parse HEAD)" = "$REV" ] || { echo "build-kernel: checkout is not at $REV" >&2; exit 1; }
export KBUILD_BUILD_TIMESTAMP=${KBUILD_BUILD_TIMESTAMP:-$(git -C "$SRC" log -1 --format=%cD "$REV")}
SDE=$(git -C "$SRC" log -1 --format=%ct "$REV")
echo "build timestamp: $KBUILD_BUILD_TIMESTAMP"

echo "== configure: defconfig + uc-pxx.config"
rm -rf "$BUILD"; mkdir -p "$BUILD"
# A fixed build user and host, as the sister projects use: the kernel version
# string names no build machine.
M="make -C $SRC O=$BUILD ARCH=arm64 CROSS_COMPILE=$CROSS KBUILD_BUILD_USER=build KBUILD_BUILD_HOST=uc-pxx-build"
$M -s defconfig uc-pxx.config
# The build runs in $BUILD, so the relative name is the copy in $BUILD.
cp "$INITRAMFS" "$BUILD/initramfs.cpio"
"$SRC/scripts/config" --file "$BUILD/.config" --set-str INITRAMFS_SOURCE initramfs.cpio \
	-e RD_XZ -e INITRAMFS_COMPRESSION_XZ
$M -s olddefconfig
WANT_KREL="$($M -s kernelversion)-g$(printf '%s' "$REV" | cut -c1-12)"
GOT_KREL=$($M -s kernelrelease)
[ "$GOT_KREL" = "$WANT_KREL" ] || {
	echo "build-kernel: the checkout gives the release $GOT_KREL, not $WANT_KREL (tags in reach of git describe, or a local change): use a checkout without tags" >&2
	exit 1
}

echo "== build: Image, $DTBS"
# shellcheck disable=SC2046 # one word per device tree
$M -j"$JOBS" Image $(for d in $DTBS; do echo "rockchip/$d"; done)
MODULES=no
if grep -q '^CONFIG_MODULES=y' "$BUILD/.config"; then
	MODULES=yes
	$M -j"$JOBS" modules
fi
KREL=$(cat "$BUILD/include/config/kernel.release")
echo "kernel release: $KREL"
[ "$KREL" = "$WANT_KREL" ] || { echo "build-kernel: the build is $KREL, not $WANT_KREL" >&2; exit 1; }

W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
if [ "$MODULES" = yes ]; then
	echo "== modules_install (stripped)"
	$M -s INSTALL_MOD_STRIP=1 INSTALL_MOD_PATH="$W/mods" modules_install
	rm -f "$W/mods/lib/modules/$KREL/build" "$W/mods/lib/modules/$KREL/source"
	[ -f "$W/mods/lib/modules/$KREL/modules.dep" ] || { echo "build-kernel: no modules.dep for $KREL" >&2; exit 1; }
fi

echo "== output: $OUT"
rm -rf "$OUT"; mkdir -p "$OUT"
OUT=$(cd "$OUT" && pwd)  # a relative --out works after the cd below
cp "$BUILD/arch/arm64/boot/Image" "$OUT/Image"
for d in $DTBS; do cp "$BUILD/arch/arm64/boot/dts/rockchip/$d" "$OUT/$d"; done
echo "$KREL" > "$OUT/kernel.release"
echo "$REV" > "$OUT/kernel.commit"
{
	echo "release=$KREL"
	echo "commit=$REV"
	echo "build_timestamp=$KBUILD_BUILD_TIMESTAMP"
	echo "initramfs_sha256=$(sha256sum < "$INITRAMFS" | cut -c1-64)"
	echo "cc=$("${CROSS}gcc" --version | head -n 1)"
	echo "ld=$("${CROSS}ld" -v | head -n 1)"
} > "$OUT/build-info.txt"
FILES="Image $DTBS kernel.release kernel.commit build-info.txt"
if [ "$MODULES" = yes ]; then
	(cd "$W/mods" && find lib -exec touch -h -d "@$SDE" {} + &&
		tar --sort=name --mtime="@$SDE" --owner=0 --group=0 --numeric-owner -cf - lib | gzip -n -6 > "$OUT/modules-$KREL.tar.gz")
	FILES="$FILES modules-$KREL.tar.gz"
fi
# shellcheck disable=SC2086 # one word per file
(cd "$OUT" && sha256sum $FILES > sha256sums.txt)
cat "$OUT/sha256sums.txt"
