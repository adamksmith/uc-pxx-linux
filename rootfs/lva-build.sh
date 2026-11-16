#!/bin/sh
# lva-build.sh ROOT OUT: build /opt/lva of a tree that has the ha profile's
# packages (install-lva.sh of the package tsx-ha: the Home Assistant device
# tsx-esphome and the voice satellite linux-voice-assistant) and pack what
# install-lva.sh makes (/opt/lva and the launcher
# /usr/local/bin/linux-voice-assistant) into OUT (lva.tar), deterministically.
# Runs INSIDE the build container (mkrootfs.sh, rootfs/r23-refs.sh), as root.
#
# The TensorFlow Lite C library for the wake word models comes from the
# tensorflow-lite-c package (tsx-aports, packages-tsx.txt). The package tsx-ha
# ships install-lva.sh and the ESPHome shim. The script copies the shim from
# the directory next to it, and it first deletes /opt/lva. So it runs from a
# copy of both. It downloads pinned Python files (the build's pip folder
# UC_PXX_PIP_DIR, default /build/pip, the snapshot's pip/), so a package cannot
# hold its result, and no unit runs it: the unit unpacks lva.tar
# (profile-apply.sh --lva).
#
# install-lva.sh builds pymicro-features from its sdist in a pip folder with a
# random name. The debug info and the build id of that library name the folder:
# they are removed (the panel never needs them). The tar: GNU format, sorted
# names, numeric owners, every time SOURCE_DATE_EPOCH (0 without it), members
# opt/lva, opt/lva/... and usr/local/bin/linux-voice-assistant (paths relative
# to the root of the tree).
set -eu
R=${1:?ROOT} OUT=${2:?OUT}
CACHE=${UC_PXX_PIP_DIR:-/build/pip}
die() { echo "lva-build.sh: $*" >&2; exit 1; }
[ -x "$R/usr/share/tsx/install-lva.sh" ] || die "the tsx-ha package did not install /usr/share/tsx/install-lva.sh"
[ -d "$R/opt/lva/shim" ] || die "no /opt/lva/shim (the package tsx-ha)"
S=/build/lva-src.$$
rm -rf "$S"; mkdir -p "$S"
cp "$R/usr/share/tsx/install-lva.sh" "$S/"
cp -a "$R/opt/lva/shim" "$S/shim"
ARCH=aarch64 LVA_CACHE=$CACHE TFLITE_SO=/usr/lib/libtensorflowlite_c.so sh "$S/install-lva.sh" "$R"
rm -rf "$S"
find "$R/opt/lva" -type f -name '*.so' | sort | while read -r f; do
	grep -q -F 'pip-req-build-' "$f" || continue
	command -v strip >/dev/null || die "$f names the pip build folder and there is no strip"
	strip --strip-debug --remove-section=.note.gnu.build-id "$f"
	grep -q -F 'pip-req-build-' "$f" && die "$f still names the pip build folder"
	echo "stripped the debug info and the build id of ${f#"$R"}"
done
[ -f "$R/usr/local/bin/linux-voice-assistant" ] && [ ! -L "$R/usr/local/bin/linux-voice-assistant" ] ||
	die "install-lva.sh made no launcher /usr/local/bin/linux-voice-assistant"
tar -C "$R" --sort=name --format=gnu --numeric-owner --mtime="@${SOURCE_DATE_EPOCH:-0}" -cf "$OUT.part" \
	opt/lva usr/local/bin/linux-voice-assistant
mv -f "$OUT.part" "$OUT"
echo "lva.tar: $(sha256sum "$OUT" | cut -d' ' -f1) $(wc -c < "$OUT") bytes, $(tar -tf "$OUT" | wc -l) members"
