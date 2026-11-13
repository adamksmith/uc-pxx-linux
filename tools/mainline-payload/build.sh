#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Build the mainline payload of the UC-P10 (contract v2, docs/mainline-payload.md):
# the folder uc-pxx-mainline/ with manifest.json, boot-template.img and
# rootfs.ext4, for the installer (uc-pxx-installer, mainline mode). Run it on
# the build host, never on a workstation. It touches no unit and runs no
# flashing tool.
#
#   tools/mainline-payload/build.sh prime --snapshot DIR [--channel URL]
#   tools/mainline-payload/build.sh build --snapshot DIR --resource FILE --vbmeta FILE --out DIR
#                                         [--inputs FILE] [--authorized-keys FILE]
#                                         [--headroom MIB] [--apk-url URL] [--keep-work]
#                                         [--step2-bootctl-inst FILE --step2-bin FILE] [--xfer-bin FILE]
#                                         [--dev-apk-key NAME.rsa.pub] [--require-both-slot]
#                                         [--autoupdate-mode manual|auto] [--ssh-access keys|setup]
#
# prime   Makes the input snapshot DIR (network): DIR/tsx is the published apk
#         tree of tsx-aports (rootfs/fetch-apk-tree.sh, --channel, default the
#         stable channel), DIR/alpine gets every Alpine file that a rootfs build
#         asks for (apk-snapshot.py serve between the build container and the
#         mirror), DIR/pip the Python files of install-lva.sh. A snapshot that
#         exists is kept: only missing files are fetched. The rootfs of this
#         run is thrown away.
# build   No network: the build container runs with --network none and reads
#         only the snapshot. The steps:
#         1. the inputs: the pins below and the digests of the snapshot. With
#            --inputs FILE every value must be the value of FILE, or the build
#            stops (a reproduction). Without it, it is a dev build: the values
#            as found, VERSION dev-<commit>, SOURCE_DATE_EPOCH the commit time
#         2. the rootfs: rootfs/build-rootfs.sh all of a clean copy of this
#            commit (git archive), with SOURCE_DATE_EPOCH, ROOTFS_UUID and
#            TSX_BUILD_ID=VERSION (mkrootfs.sh then makes the same bytes)
#         3. the boot template: /boot/uc-pxx-lts.img of the rootfs. That is
#            the image of the kernel package uc-pxx-kernel-lts (kernel/mkimage.sh
#            with an empty resource, the real initramfs built in). So the
#            slot boots the kernel that the rootfs ships, and uc-pxx-update-boot
#            later sees boot_a = its package image. The template must be of
#            the reviewed kernel pin, and kernel/mkimage.sh of this commit must
#            make it again byte for byte from its own Linux Image and the
#            device tree of the package
#         4. boot_assembled: kernel/mkimage.sh --resource RESOURCE with the
#            same inputs (the image that the installer writes to boot_a).
#            payload.py assembles the template again by itself and stops when
#            the two differ. Only the sha256 and the size stay: the assembled
#            image holds the vendor resource and is deleted
#         5. the patched vbmeta: vbmeta-patch.py patch of --vbmeta. Only its
#            sha256 stays (the installer makes it again from vbmeta_b)
#         6. manifest.json (payload.py manifest)
# Outputs in --out: uc-pxx-mainline/ (or uc-pxx-mainline.OVER-CAP/ when the
# assembled image is larger than the vbmeta boot cap: then the exit status is
# 3, and the installer must never get that folder), inputs.txt (the inputs
# of this build), build-info.txt, rootfs.manifest, rootfs.sizes, SHA256SUMS.
#
# --resource  the stock boot resource of the UC-P10 (sha256 290ef405...). A
#             vendor file: it stays on the build host, it is never copied into
#             the outputs, and the assembled image is deleted.
# --vbmeta    the signed vbmeta of 1.0.0.94 userdebug (sha256 7958c09b...). A
#             vendor file: as the resource, it stays on the build host and
#             the patched copy is deleted after the manifest is written.
# --headroom  free space in rootfs.ext4 in MiB (IMG_HEADROOM_MB of
#             mkrootfs.sh), default 0: the payload must fit the P10-INSTALL
#             drive, and the initramfs grows the file system to fill system_a
#             on the first boot. mkrootfs.sh adds 5 % of the content anyway.
# --apk-url   the apk repository that the panel lists (TSX_APK_URL of
#             mkrootfs.sh; default https://tsx-aports.unexceptional.net, the
#             stable channel). Use the channel of the snapshot: the uc-pxx
#             packages are on the testing channel only (2026-11).
# --authorized-keys  ssh public keys for root, baked into rootfs.ext4 (the
#             release workflow takes them from TSX_AUTHORIZED_KEYS). Default:
#             none, so the image has no ssh login until the panel gets a key
#             (docs/rootfs.md "Root login"). The inputs record the sha256.
#             A payload with keys is for the units of the key owner only:
#             build-info.txt says so. The root password stays locked.
# --step2-bootctl-inst  a separate option, off by default
#             (MAINLINE-STEP2-DESIGN Q-S8): the reviewed static
#             uc-pxx-bootctl-inst r2 (sha256 20aa6bc5...). The rootfs gets it at
#             /usr/libexec/uc-pxx-step2/uc-pxx-bootctl-inst (root, 0700) for
#             step 2. RULES.md allows it in no slot today, and the installer
#             gate refuses such a payload: it is for no unit before its RULES
#             line. Without it the rootfs build stops on any file of that name.
#             The inputs record the sha256 (or none).
# --step2-bin  with --step2-bootctl-inst only (required with it): the pinned
#             uc-pxx-step2 (uc-pxx-installer ci/build-step2.sh). The rootfs
#             gets it at /usr/libexec/uc-pxx-step2/uc-pxx-step2 (root, 0700)
#             and the OpenRC service uc-pxx-step2 (rootfs/mkrootfs.sh). With
#             SSH_ACCESS=keys (the maintainer's key) it is a SUPERVISED STEP-2
#             build (the supervised marker /etc/uc-pxx-step2/supervised); with
#             SSH_ACCESS=setup an END-USER STEP-2 build (no /etc/uc-pxx-step2:
#             its step 2 may start by itself). The inputs record
#             STEP2_BIN_SHA256.
# --xfer-bin  the pinned uc-pxx-xfer (uc-pxx-installer ci/build-xfer.sh): the
#             USB set of a both-slot build (rootfs/mkrootfs.sh UC_PXX_XFER_BIN,
#             docs/usb.md): the WebUSB interface (uc-pxx-usb), its conf (the
#             USB network OFF), the slot's finish list, the user uc-pxx-xfer.
#             Required with --require-both-slot. The inputs record
#             XFER_BIN_SHA256.
# --dev-apk-key  TEST ONLY: the public key of a private build of uc-pxx
#             packages in the snapshot's tsx/ tree that are not published yet
#             (for example the both-slot packages before their tag). The
#             rootfs build trusts it for the package install only; the image
#             never trusts it and has /etc/tsx/dev-apk-key. The inputs record
#             the sha256 (or none); build-info.txt says "DEV PACKAGES". Never
#             publish such a payload.
# --require-both-slot  stop (exit 1) unless the payload is a both-slot build
#             of this commit (payload.py both-slot; the verdict is in
#             both-slot.txt and build-info.txt either way).
#
# The inputs file: one KEY=VALUE per line, "#" lines are comments, each key
# once, no other key:
#   FORMAT              uc-pxx-mainline-payload-inputs-6
#   VERSION             the version of the manifest: a release tag or dev-<commit>
#   SOURCE_DATE_EPOCH   seconds
#   UC_PXX_LINUX_COMMIT HEAD of this checkout (a clean tree)
#   KERNEL_REV          kernel/KERNEL_REV.lts = the reviewed pin
#   MKIMAGE_SHA256, SHIM_SHA256   kernel/mkimage.sh, bootloader/shim.S
#   RESOURCE_SHA256     --resource (always 290ef405...)
#   VBMETA_SHA256       --vbmeta (always 7958c09b...)
#   ALPINE_IMAGE        the build container, by digest (linux/arm64)
#   ALPINE_IMAGE_ID     its image id
#   ALPINE_SNAPSHOT, TSX_SNAPSHOT, PIP_SNAPSHOT   "sha256 count" of the
#                       snapshot folders (apk-snapshot.py digest)
#   PROFILE             the rootfs profile (ha)
#   ROOTFS_UUID         the UUID of rootfs.ext4
#   IMG_HEADROOM_MB     free space in rootfs.ext4 (mkrootfs.sh; --headroom)
#   TSX_APK_URL         the apk repository that the panel lists
#   AUTHORIZED_KEYS_SHA256  none, or the sha256 of --authorized-keys
#   AUTOUPDATE_MODE     manual (the default: the slot never installs by itself;
#                       /etc/tsx/autoupdate.conf MODE=manual, AUTO_RESTART=off)
#                       or auto (--autoupdate-mode; the tsx-autoupdate defaults)
#   SSH_ACCESS          keys (the maintainer build: --authorized-keys, sshd on)
#                       or setup (the end-user build: no key, sshd off until the
#                       setup page gives root an SSH key; docs/mainline-payload.md
#                       "SSH access"). The default: keys with --authorized-keys,
#                       else setup
#   STEP2_BOOTCTL_INST_SHA256  none, or the sha256 of --step2-bootctl-inst
#   STEP2_BIN_SHA256    none, or the sha256 of --step2-bin
#   XFER_BIN_SHA256     none, or the sha256 of --xfer-bin
#   DEV_APK_KEY_SHA256  none, or the sha256 of --dev-apk-key
#   CROSS_CC_VERSION, CROSS_LD_VERSION, DTC_VERSION, MKBOOTIMG_SHA256
#                       the host tools of kernel/mkimage.sh
#
# Host tools: docker (qemu-user binfmt for linux/arm64), python3, git, curl,
# tar, aarch64-linux-gnu-gcc/-ld/-objcopy, mkbootimg, fdtget, fdtput.
set -euo pipefail
export LC_ALL=C TZ=UTC
umask 022
HERE=$(cd "$(dirname "$0")/../.." && pwd)
T=$HERE/tools/mainline-payload
PY="python3 -I"
CROSS=${CROSS_COMPILE:-aarch64-linux-gnu-}
REVIEWED_KERNEL_REV=d02e92631f2810a4a43fb6f09824afb9b0044ee2
RESOURCE_SHA=290ef40577d434d702c3544076dbebd6ddd17e16087eff0e84c92549d67bb363
# the signed vbmeta of 1.0.0.94 userdebug (the source of the patched vbmeta_a)
VBMETA_SHA=7958c09b4fb6fb3d54a2382682074b4812e92cc1d81ca3183b20f03ff52f5f5c
# kernel/mkimage.sh as reviewed with the boot control (ucp10 RULES.md): it writes the token
MKIMAGE_SHA=98ef579ce1f152463c8902c53c2f2f8edfbdfd6b8a0d40d650c59844d893703f
# alpine:3.24 for linux/arm64 (3.24.3), the image of the other uc-pxx builds
ALPINE_REF_DEFAULT=alpine@sha256:e311ae748be7f56ae5cba304bc488f0786df68ee507513f654a5cc8597cffb42
ALPINE=v3.24
UPSTREAM=${UPSTREAM_MIRROR:-https://dl-cdn.alpinelinux.org/alpine}
FMT=uc-pxx-mainline-payload-inputs-7
# uc-pxx-bootctl-inst r2 (RULES.md: the installer RAM image only; Q-S8: a step-2 rootfs)
STEP2_INST_SHA=20aa6bc5d2146faace461eec0b50f741c681b3c58827788b9b806d9444b00203
KEYS="FORMAT VERSION SOURCE_DATE_EPOCH UC_PXX_LINUX_COMMIT KERNEL_REV MKIMAGE_SHA256 SHIM_SHA256
RESOURCE_SHA256 VBMETA_SHA256 ALPINE_IMAGE ALPINE_IMAGE_ID ALPINE_SNAPSHOT TSX_SNAPSHOT PIP_SNAPSHOT PROFILE
ROOTFS_UUID IMG_HEADROOM_MB TSX_APK_URL AUTHORIZED_KEYS_SHA256 AUTOUPDATE_MODE SSH_ACCESS STEP2_BOOTCTL_INST_SHA256 STEP2_BIN_SHA256 XFER_BIN_SHA256 DEV_APK_KEY_SHA256 CROSS_CC_VERSION CROSS_LD_VERSION
DTC_VERSION MKBOOTIMG_SHA256"
die() { echo "mainline-payload: $*" >&2; exit 1; }
usage() { sed -n '9,14p' "$0" >&2; exit 2; }
T0=$(date +%s)
step() { echo "== $* ($(( $(date +%s) - T0 )) s)"; }
sha() { sha256sum < "$1" | cut -c1-64; }

CMD=${1:-}; [ $# -gt 0 ] && shift
SNAP= RES= VBM= OUT= INPUTS= KEYSFILE= S2FILE= S2BFILE= XFFILE= DKFILE= REQBS=0 HEADROOM0= KEEP=0 AUMODE0= SSHACC0= CHANNEL=https://tsx-aports.unexceptional.net APKURL0=https://tsx-aports.unexceptional.net
while [ $# -gt 0 ]; do
	case $1 in
	--snapshot) SNAP=${2:?}; shift;;
	--resource) RES=${2:?}; shift;;
	--vbmeta) VBM=${2:?}; shift;;
	--headroom) HEADROOM0=${2:?}; shift;;
	--out) OUT=${2:?}; shift;;
	--inputs) INPUTS=${2:?}; shift;;
	--authorized-keys) KEYSFILE=${2:?}; shift;;
	--step2-bootctl-inst) S2FILE=${2:?}; shift;;
	--step2-bin) S2BFILE=${2:?}; shift;;
	--xfer-bin) XFFILE=${2:?}; shift;;
	--dev-apk-key) DKFILE=${2:?}; shift;;
	--require-both-slot) REQBS=1;;
	--autoupdate-mode) AUMODE0=${2:?}; shift;;
	--ssh-access) SSHACC0=${2:?}; shift;;
	--channel) CHANNEL=${2:?}; shift;;
	--apk-url) APKURL0=${2:?}; shift;;
	--keep-work) KEEP=1;;
	*) usage;;
	esac
	shift
done
case $CMD in prime|build) ;; *) usage;; esac
[ -n "$SNAP" ] || usage
# The kernel pin first: nothing runs for a checkout with another pin.
REV=$(grep -v '^#' "$HERE/kernel/KERNEL_REV.lts" | head -n 1 | tr -d ' \n')
[ "$REV" = "$REVIEWED_KERNEL_REV" ] || die "kernel/KERNEL_REV.lts pins $REV, not the reviewed kernel $REVIEWED_KERNEL_REV"
# The commit: always a clean tree. The build runs from a copy of the commit.
command -v git >/dev/null || die "git is not installed"
COMMIT=$(git -C "$HERE" rev-parse HEAD 2>/dev/null) || die "$HERE is not a git checkout"
[ -z "$(git -C "$HERE" status --porcelain)" ] || die "$HERE has changes or untracked files: commit them first"
for t in docker python3 tar; do command -v $t >/dev/null || die "$t is not installed"; done
[ -e /proc/sys/fs/binfmt_misc/qemu-aarch64 ] || die "no qemu-aarch64 binfmt (qemu-user-static)"
mkdir -p "$SNAP"; SNAP=$(cd "$SNAP" && pwd)

# alpine_image REF: the build container, checked by its image id
alpine_image() {
	docker image inspect "$1" >/dev/null 2>&1 || docker pull -q "$1" >/dev/null || die "cannot get $1"
	ALPINE_ID=$(docker image inspect -f '{{.Id}}' "$1")
	[ "$(docker image inspect -f '{{.Architecture}}' "$ALPINE_ID")" = arm64 ] || die "$1 is not an arm64 image"
	IMAGE=uc-pxx-payload-alpine:${ALPINE_ID#sha256:}
	IMAGE=${IMAGE:0:44}
	docker tag "$ALPINE_ID" "$IMAGE"
}

# own_back DIR: the build container writes as root into the Python folder
# (install-lva.sh unpacks its sources there). Give the files back to the user,
# so that the folder can be removed.
own_back() {
	[ -d "$1" ] || return 0
	docker run --rm --network none --platform linux/arm64 -v "$1:/x" "$IMAGE" chown -R "$(id -u):$(id -g)" /x
}

# copy_source DIR: this commit, nothing else (no untracked file such as
# rootfs/authorized_keys)
copy_source() {
	rm -rf "$1"; mkdir -p "$1"
	git -C "$HERE" archive --format=tar "$COMMIT" | tar -C "$1" -xf -
}

# rootfs_build SRC PIP NET MIRROR_ENV...: rootfs/build-rootfs.sh all of the copy
rootfs_build() {
	local src=$1 pip=$2 net=$3; shift 3
	env -u TSX_COMMON -u UC_PXX_DEV_OVERLAY -u UC_PXX_DEV_COMMON -u TSX_DEV_ROOT_HASH -u AUTHORIZED_KEYS \
		-u KVER -u IMG_MB -u UC_PXX_SPLASH_SIZES -u TSX_DEV_RESCUE_KEYS -u TSX_DEV_RESCUE_HASH \
		-u UC_PXX_APK_MIRROR -u UC_PXX_MIRROR_URL -u UC_PXX_DEV_OVERLAY -u RTL8363_INIT -u UC_PXX_BOOTCTL -u UC_PXX_REBOOT \
		-u UC_PXX_STEP2_BOOTCTL_INST -u UC_PXX_STEP2_BIN -u UC_PXX_XFER_BIN -u UC_PXX_DEV_APK_KEY \
		-u UC_PXX_AUTOUPDATE_MODE -u UC_PXX_SSH_ACCESS \
		ALPINE=$ALPINE IMAGE="$IMAGE" PROFILE="$PROFILE" TSX_APK_LOCAL="$SNAP/tsx" \
		TSX_APK_URL="$APKURL" TSX_BUILD_ID="$VERSION" SOURCE_DATE_EPOCH="$SDE" ROOTFS_UUID="$UUID" \
		IMG_HEADROOM_MB="$HEADROOM" UC_PXX_PIP_CACHE="$pip" UC_PXX_DOCKER_NET="$net" \
		AUTHORIZED_KEYS="$AKEYS" UC_PXX_AUTOUPDATE_MODE="${GOT[AUTOUPDATE_MODE]}" UC_PXX_SSH_ACCESS="${GOT[SSH_ACCESS]}" \
		${S2INST:+UC_PXX_STEP2_BOOTCTL_INST="$S2INST"} ${S2BIN:+UC_PXX_STEP2_BIN="$S2BIN"} ${XFBIN:+UC_PXX_XFER_BIN="$XFBIN"} \
		${DEVKEY:+UC_PXX_DEV_APK_KEY="$DEVKEY"} "$@" "$src/rootfs/build-rootfs.sh" all
}

# ---- the inputs ----------------------------------------------------------------
declare -A IN=() GOT=()
if [ -n "$INPUTS" ]; then
	[ "$CMD" = build ] || die "--inputs is for build"
	n=0
	while IFS= read -r l || [ -n "$l" ]; do
		n=$((n + 1))
		case $l in ''|'#'*) continue;; esac
		case $l in *[![:print:]]*) die "$INPUTS line $n: a byte that is not printable ASCII";; esac
		k=${l%%=*} v=${l#*=}
		[ "$k" != "$l" ] || die "$INPUTS line $n: not KEY=VALUE"
		case " $(echo $KEYS) " in *" $k "*) ;; *) die "$INPUTS line $n: unknown key $k";; esac
		[ -z "${IN[$k]+x}" ] || die "$INPUTS line $n: $k twice"
		IN[$k]=$v
	done < "$INPUTS"
	for k in $KEYS; do [ -n "${IN[$k]+x}" ] || die "$INPUTS has no $k"; done
	[ "${IN[FORMAT]}" = $FMT ] || die "$INPUTS: FORMAT is not $FMT"
fi
pin() {
	GOT[$1]=$2
	if [ -n "$INPUTS" ] && [ "${IN[$1]}" != "$2" ]; then die "$1 is '$2', the inputs file says '${IN[$1]}'"; fi
}
choose() { if [ -n "$INPUTS" ]; then GOT[$1]=${IN[$1]}; else GOT[$1]=$2; fi; }

choose FORMAT $FMT
choose VERSION "dev-${COMMIT:0:12}"
choose SOURCE_DATE_EPOCH "$(git -C "$HERE" log -1 --format=%ct "$COMMIT")"
choose PROFILE ha
choose IMG_HEADROOM_MB "${HEADROOM0:-0}"
[ -z "$INPUTS" ] || [ -z "$HEADROOM0" ] || [ "$HEADROOM0" = "${IN[IMG_HEADROOM_MB]}" ] || die "--headroom differs from IMG_HEADROOM_MB of the inputs file"
choose TSX_APK_URL "$APKURL0"
[ -z "$INPUTS" ] || [ "$APKURL0" = https://tsx-aports.unexceptional.net ] || [ "$APKURL0" = "${IN[TSX_APK_URL]}" ] || die "--apk-url differs from TSX_APK_URL of the inputs file"
VERSION=${GOT[VERSION]} SDE=${GOT[SOURCE_DATE_EPOCH]} PROFILE=${GOT[PROFILE]}
HEADROOM=${GOT[IMG_HEADROOM_MB]} APKURL=${GOT[TSX_APK_URL]}
[[ $VERSION =~ ^[A-Za-z0-9._+-]{1,64}$ ]] || die "VERSION '$VERSION': only letters, digits and . _ + - (1 to 64)"
[[ $SDE =~ ^[1-9][0-9]{0,10}$ ]] || die "SOURCE_DATE_EPOCH '$SDE' is not a time in seconds"
case $PROFILE in console|kiosk|ha) ;; *) die "PROFILE '$PROFILE' is not console, kiosk or ha";; esac
[[ $HEADROOM =~ ^[0-9]{1,4}$ ]] || die "IMG_HEADROOM_MB '$HEADROOM' is not a number of MiB"
[[ $APKURL =~ ^https://[A-Za-z0-9./_-]+$ ]] || die "TSX_APK_URL '$APKURL' is not an https URL"
# The UUID of rootfs.ext4 follows from the version and the time in a dev build.
U=$(printf 'uc-pxx-mainline rootfs %s %s' "$VERSION" "$SDE" | sha256sum | cut -c1-32)
choose ROOTFS_UUID "${U:0:8}-${U:8:4}-4${U:13:3}-8${U:17:3}-${U:20:12}"
UUID=${GOT[ROOTFS_UUID]}
[[ $UUID =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] || die "ROOTFS_UUID '$UUID' is not a lower-case UUID"
choose ALPINE_IMAGE "$ALPINE_REF_DEFAULT"
[[ ${GOT[ALPINE_IMAGE]} =~ ^[a-z0-9./_-]+@sha256:[0-9a-f]{64}$ ]] || die "ALPINE_IMAGE '${GOT[ALPINE_IMAGE]}' is not an image reference by digest"
alpine_image "${GOT[ALPINE_IMAGE]}"
pin ALPINE_IMAGE_ID "$ALPINE_ID"
pin UC_PXX_LINUX_COMMIT "$COMMIT"
pin KERNEL_REV "$REV"
pin MKIMAGE_SHA256 "$(sha "$HERE/kernel/mkimage.sh")"
[ "${GOT[MKIMAGE_SHA256]}" = $MKIMAGE_SHA ] || die "kernel/mkimage.sh has sha256 ${GOT[MKIMAGE_SHA256]}, not the reviewed $MKIMAGE_SHA"
pin SHIM_SHA256 "$(sha "$HERE/bootloader/shim.S")"
AKEYS=/nonexistent
if [ -n "$KEYSFILE" ]; then
	[ -s "$KEYSFILE" ] || die "--authorized-keys $KEYSFILE is empty or missing"
	grep -q 'PRIVATE KEY' "$KEYSFILE" && die "--authorized-keys $KEYSFILE holds a private key"
	AKEYS=$(readlink -f "$KEYSFILE")
	pin AUTHORIZED_KEYS_SHA256 "$(sha "$AKEYS")"
else
	pin AUTHORIZED_KEYS_SHA256 none
fi
# the tsx-autoupdate mode (RC-5 release review MINOR-2: manual by default)
if [ -n "$INPUTS" ] && [ -n "$AUMODE0" ] && [ "$AUMODE0" != "${IN[AUTOUPDATE_MODE]}" ]; then die "--autoupdate-mode differs from AUTOUPDATE_MODE of the inputs file"; fi
choose AUTOUPDATE_MODE "${AUMODE0:-manual}"
case ${GOT[AUTOUPDATE_MODE]} in manual|auto) ;; *) die "AUTOUPDATE_MODE '${GOT[AUTOUPDATE_MODE]}' is not manual or auto";; esac
# the SSH access: keys (the maintainer build) or setup (the end-user build)
if [ -n "$INPUTS" ] && [ -n "$SSHACC0" ] && [ "$SSHACC0" != "${IN[SSH_ACCESS]}" ]; then die "--ssh-access differs from SSH_ACCESS of the inputs file"; fi
choose SSH_ACCESS "${SSHACC0:-$([ -n "$KEYSFILE" ] && echo keys || echo setup)}"
case ${GOT[SSH_ACCESS]} in
keys) [ -n "$KEYSFILE" ] || die "SSH_ACCESS=keys needs --authorized-keys";;
setup) [ -z "$KEYSFILE" ] || die "SSH_ACCESS=setup (the end-user build) takes no --authorized-keys";;
*) die "SSH_ACCESS '${GOT[SSH_ACCESS]}' is not keys or setup";;
esac
S2INST=
if [ -n "$S2FILE" ]; then
	[ -f "$S2FILE" ] || die "--step2-bootctl-inst $S2FILE: no such file"
	S2INST=$(readlink -f "$S2FILE")
	pin STEP2_BOOTCTL_INST_SHA256 "$(sha "$S2INST")"
	[ "${GOT[STEP2_BOOTCTL_INST_SHA256]}" = $STEP2_INST_SHA ] || die "--step2-bootctl-inst has sha256 ${GOT[STEP2_BOOTCTL_INST_SHA256]}, not the reviewed r2 $STEP2_INST_SHA"
	echo "WARNING: a STEP-2 build (--step2-bootctl-inst): uc-pxx-bootctl-inst r2 in the rootfs; for no unit before its RULES line"
else
	pin STEP2_BOOTCTL_INST_SHA256 none
fi
S2BIN=
if [ -n "$S2BFILE" ]; then
	[ -n "$S2FILE" ] || die "--step2-bin needs --step2-bootctl-inst (a STEP-2 build)"
	[ -f "$S2BFILE" ] || die "--step2-bin $S2BFILE: no such file"
	S2BIN=$(readlink -f "$S2BFILE")
	pin STEP2_BIN_SHA256 "$(sha "$S2BIN")"
else
	[ -z "$S2FILE" ] || die "--step2-bootctl-inst needs --step2-bin (uc-pxx-step2)"
	pin STEP2_BIN_SHA256 none
fi
XFBIN=
if [ -n "$XFFILE" ]; then
	[ -f "$XFFILE" ] || die "--xfer-bin $XFFILE: no such file"
	XFBIN=$(readlink -f "$XFFILE")
	pin XFER_BIN_SHA256 "$(sha "$XFBIN")"
else
	[ "$REQBS" = 0 ] || die "--require-both-slot needs --xfer-bin (the USB set of every both-slot build, docs/usb.md)"
	pin XFER_BIN_SHA256 none
fi
DEVKEY=
if [ -n "$DKFILE" ]; then
	[ -f "$DKFILE" ] || die "--dev-apk-key $DKFILE: no such file"
	case ${DKFILE##*/} in *[!A-Za-z0-9._-]*|.*) die "--dev-apk-key: a bad file name";; *.rsa.pub) ;; *) die "--dev-apk-key: the name must end in .rsa.pub";; esac
	grep -q 'PRIVATE KEY' "$DKFILE" && die "--dev-apk-key $DKFILE holds a private key"
	case ${DKFILE##*/} in tsx-mainline-*|alpine-devel@*) die "--dev-apk-key: the name ${DKFILE##*/} is the name of a trusted key";; esac
	for k in "$HERE"/rootfs/overlay/etc/apk/keys/*; do
		[ "${k##*/}" != "${DKFILE##*/}" ] || die "--dev-apk-key: the name ${DKFILE##*/} is the project key's"
	done
	grep -q -- '-----BEGIN PUBLIC KEY-----' "$DKFILE" || die "--dev-apk-key $DKFILE is not a public key"
	DEVKEY=$(readlink -f "$DKFILE")
	pin DEV_APK_KEY_SHA256 "$(sha "$DEVKEY")"
	echo "WARNING: DEV PACKAGES (--dev-apk-key ${DKFILE##*/}): uc-pxx packages of a private build; never publish this payload"
else
	pin DEV_APK_KEY_SHA256 none
fi

if [ "$CMD" = prime ]; then
	for t in curl awk; do command -v $t >/dev/null || die "$t is not installed"; done
	W=$SNAP/.prime; rm -rf "$W"; mkdir -p "$W" "$SNAP/alpine" "$SNAP/pip"
	step "prime 1: the apk tree of tsx-aports ($CHANNEL) -> $SNAP/tsx"
	ALPINE=$ALPINE "$HERE/rootfs/fetch-apk-tree.sh" "$SNAP/tsx" "$CHANNEL" | grep -v 'already here' || true
	rm -f "$SNAP"/tsx/*/*/*/.files
	step "prime 2: a rootfs build through the snapshot server -> $SNAP/alpine, $SNAP/pip"
	GW=$(docker network inspect bridge -f '{{(index .IPAM.Config 0).Gateway}}')
	PORT=$(python3 -c 'import socket; s=socket.socket(); s.bind(("",0)); print(s.getsockname()[1])')
	$PY "$T/apk-snapshot.py" serve "$SNAP/alpine" "$UPSTREAM" --bind "$GW" --port "$PORT" 2> "$W/server.log" &
	SRV=$!
	trap 'kill $SRV 2>/dev/null || true' EXIT
	sleep 1
	kill -0 $SRV 2>/dev/null || { cat "$W/server.log"; die "the snapshot server did not start"; }
	copy_source "$W/src"
	cp -a "$SNAP/pip" "$W/pip"
	rootfs_build "$W/src" "$W/pip" bridge UC_PXX_MIRROR_URL="http://$GW:$PORT/alpine" > "$W/rootfs.log" 2>&1 ||
		{ tail -30 "$W/rootfs.log"; die "the priming rootfs build failed (log $W/rootfs.log)"; }
	kill $SRV; trap - EXIT
	# keep the fetched Python files, not the unpacked sources of install-lva.sh
	find "$W/pip" -maxdepth 1 -type f -exec cp -n {} "$SNAP/pip/" \;
	grep -c '^apk-snapshot: kept' "$W/server.log" | sed 's/^/files fetched from the mirror: /' || true
	own_back "$W/pip"
	rm -rf "$W"
	for d in alpine tsx pip; do echo "$d: $($PY "$T/apk-snapshot.py" digest "$SNAP/$d")"; done
	step "prime done: $SNAP"
	exit 0
fi

# ---- build --------------------------------------------------------------------------
[ -n "$RES" ] && [ -n "$VBM" ] && [ -n "$OUT" ] || usage
[ -f "$RES" ] || die "no resource $RES"
RES=$(readlink -f "$RES")
pin RESOURCE_SHA256 "$(sha "$RES")"
[ "${GOT[RESOURCE_SHA256]}" = $RESOURCE_SHA ] || die "--resource has sha256 ${GOT[RESOURCE_SHA256]}, not the stock resource $RESOURCE_SHA"
[ -f "$VBM" ] || die "no vbmeta $VBM"
VBM=$(readlink -f "$VBM")
pin VBMETA_SHA256 "$(sha "$VBM")"
[ "${GOT[VBMETA_SHA256]}" = $VBMETA_SHA ] || die "--vbmeta has sha256 ${GOT[VBMETA_SHA256]}, not the signed 1.0.0.94 userdebug vbmeta $VBMETA_SHA"
for t in "${CROSS}gcc" "${CROSS}ld" "${CROSS}objcopy" mkbootimg fdtget fdtput; do command -v "$t" >/dev/null || die "$t is not installed"; done
pin CROSS_CC_VERSION "$("${CROSS}gcc" --version | head -n 1)"
pin CROSS_LD_VERSION "$("${CROSS}ld" -v | head -n 1)"
pin DTC_VERSION "$(fdtput --version 2>&1 | head -n 1)"
pin MKBOOTIMG_SHA256 "$(sha "$(command -v mkbootimg)")"
for d in alpine tsx pip; do
	[ -d "$SNAP/$d" ] || die "the snapshot $SNAP has no $d/ (run prime first)"
done
[ -r "$SNAP/alpine/$ALPINE/main/aarch64/APKINDEX.tar.gz" ] || die "the snapshot $SNAP/alpine has no $ALPINE/main index (run prime first)"
pin ALPINE_SNAPSHOT "$($PY "$T/apk-snapshot.py" digest "$SNAP/alpine")"
pin TSX_SNAPSHOT "$($PY "$T/apk-snapshot.py" digest "$SNAP/tsx")"
pin PIP_SNAPSHOT "$($PY "$T/apk-snapshot.py" digest "$SNAP/pip")"

[ ! -e "$OUT" ] || [ -z "$(ls -A "$OUT")" ] || die "--out $OUT is not empty: a build starts from nothing"
mkdir -p "$OUT"; OUT=$(cd "$OUT" && pwd)
W=$OUT/work; mkdir -p "$W"
# V: the vendor intermediates (the assembled image with the resource, the
# patched vbmeta), in a private folder outside --out, removed on every exit
V=$(mktemp -d "${TMPDIR:-/tmp}/uc-pxx-payload-vendor.XXXXXX"); chmod 700 "$V"
trap 'rm -rf "$V"' EXIT
{
	echo "# The inputs of a build of the UC-P10 mainline payload (tools/mainline-payload/build.sh build)."
	[ -n "$INPUTS" ] || echo "# DEV BUILD (no --inputs): the values as found on $(hostname) at $(date -u +%Y-%m-%dT%H:%MZ)."
	for k in $KEYS; do echo "$k=${GOT[$k]}"; done
} > "$OUT/inputs.txt"
if [ -n "$INPUTS" ]; then echo "inputs: $INPUTS (sha256 $(sha "$INPUTS")), all pins match"
else echo "inputs: DEV BUILD, VERSION $VERSION, SOURCE_DATE_EPOCH $SDE"; fi

step "1. the rootfs ($PROFILE, offline, from the snapshot)"
copy_source "$W/src"
cp -a "$SNAP/pip" "$W/pip"
rootfs_build "$W/src" "$W/pip" none UC_PXX_APK_MIRROR="$SNAP/alpine" > "$W/rootfs.log" 2>&1 ||
	{ tail -30 "$W/rootfs.log"; die "the rootfs build failed (log $W/rootfs.log)"; }
RO=$W/src/rootfs/out
grep -E '^(rootfs total|root password|kernel modules)' "$RO/rootfs.sizes" || true
# no vendor file in the rootfs (the content list of the tarball; the ext4 image
# has the same files) and no Rockchip resource
UC_PXX_CHECK_SKIP_EXT4=1 sh "$W/src/ci/check-no-proprietary.sh" "$RO" > "$W/no-proprietary.log" 2>&1 ||
	{ cat "$W/no-proprietary.log"; die "the rootfs holds a vendor file"; }
$PY "$T/payload.py" scan-tar "$RO/rootfs.tar.gz" || die "the rootfs holds a Rockchip resource"

step "2. the boot template (/boot/uc-pxx-lts.img of the kernel package in the rootfs)"
mkdir -p "$W/k"
tar -C "$W/k" -xzf "$RO/rootfs.tar.gz" ./boot/uc-pxx-lts.img ./usr/share/uc-pxx/dtbs-lts/rk3399-crestron-ucp10.dtb \
	./usr/share/uc-pxx/kernel-lts.release
TPL=$W/k/boot/uc-pxx-lts.img DTB=$W/k/usr/share/uc-pxx/dtbs-lts/rk3399-crestron-ucp10.dtb
$PY "$T/payload.py" check-template "$TPL" "$HERE/kernel/KERNEL_REV.lts" > "$W/template.info" || die "the boot template fails its check"
cat "$W/template.info"
TOKEN=$(sed -n 's/^token=//p' "$W/template.info")
KREL=$(sed -n 's/^release=//p' "$W/template.info")
[ "$KREL" = "$(cat "$W/k/usr/share/uc-pxx/kernel-lts.release")" ] || die "the kernel package names another release than its image"
$PY "$T/payload.py" initramfs "$TPL" "$W/initramfs.cpio" > "$W/initramfs.info" || die "no initramfs in the template"
cat "$W/initramfs.info"
grep -q '^program_rtl8363_init=missing' "$W/initramfs.info" && echo "WARNING: the initramfs has no rtl8363-init (the rescue cannot set up the switch)"
$PY "$T/payload.py" both-slot "$RO/rootfs.tar.gz" "$W/initramfs.cpio" "$W/src" > "$W/both-slot.txt" ||
	die "the both-slot check failed"
cat "$W/both-slot.txt"
BOTH=$(sed -n 's/^both_slot=//p' "$W/both-slot.txt")
[ "$REQBS" = 0 ] || [ "$BOTH" = yes ] || die "--require-both-slot: the payload is not a both-slot build of $COMMIT (both-slot.txt)"
$PY "$T/payload.py" split "$TPL" "$W/Image"
: > "$W/empty.res"
bash "$HERE/kernel/mkimage.sh" --resource "$W/empty.res" --board "$TOKEN" "$W/Image" "$DTB" "$W/remade.img" > "$W/mkimage-template.log"
cmp -s "$W/remade.img" "$TPL" || die "kernel/mkimage.sh of this commit does not make the template again from its Image and device tree"
echo "kernel/mkimage.sh makes the template again byte for byte (token $TOKEN)"

step "3. boot_assembled (kernel/mkimage.sh --resource, the stock resource)"
bash "$HERE/kernel/mkimage.sh" --resource "$RES" --board "$TOKEN" "$W/Image" "$DTB" "$V/assembled.img" > "$W/mkimage-assembled.log"

step "4. the patched vbmeta (vbmeta-patch.py: only the boot image_size of the signed vbmeta)"
$PY "$T/vbmeta-patch.py" patch "$VBM" "$V/vbmeta-patched.img" > "$W/vbmeta-patch.info" || die "the vbmeta patch was refused"
cat "$W/vbmeta-patch.info"

step "5. manifest.json"
mkdir -p "$W/p"
cp "$TPL" "$W/p/boot-template.img"
cp "$RO/rootfs.ext4" "$W/p/rootfs.ext4"
rc=0
$PY "$T/payload.py" manifest --version "$VERSION" --pin "$HERE/kernel/KERNEL_REV.lts" --template "$W/p/boot-template.img" \
	--resource "$RES" --assembled "$V/assembled.img" --rootfs "$W/p/rootfs.ext4" \
	--vbmeta "$VBM" --vbmeta-patched "$V/vbmeta-patched.img" --out "$W/p/manifest.json" \
	--allow-over-cap > "$W/manifest.log" || rc=$?
cat "$W/manifest.log"
[ "$rc" = 0 ] || [ "$rc" = 3 ] || die "the manifest generator refused the payload"
# the assembled image holds the vendor resource, the patched vbmeta is a
# vendor file: only their sha256 and sizes stay (the EXIT trap removes $V
# also after a refusal)
rm -f "$V/assembled.img" "$V/vbmeta-patched.img"
DIR=uc-pxx-mainline
[ "$rc" = 0 ] || DIR=uc-pxx-mainline.OVER-CAP
mv "$W/p" "$OUT/$DIR"
cp "$RO/rootfs.manifest" "$RO/rootfs.sizes" "$W/both-slot.txt" "$OUT/"

step "6. the record"
TS=$(stat -c %s "$OUT/$DIR/boot-template.img") RS=$(stat -c %s "$OUT/$DIR/rootfs.ext4") MS=$(stat -c %s "$OUT/$DIR/manifest.json")
DRIVE=$((1200 * 1048576))
TOTAL=$((TS + RS + MS))
{
	echo "UC-P10 mainline payload, contract v2 (docs/mainline-payload.md)"
	echo "version $VERSION, uc-pxx-linux $COMMIT, kernel $REV ($KREL), token $TOKEN"
	sed -n 's/^\(boot\|vbmeta\|rootfs\) /&/p' "$W/manifest.log"
	echo "rootfs.ext4 headroom: IMG_HEADROOM_MB=$HEADROOM (mkrootfs.sh adds 5 % of the content)"
	if [ "${GOT[AUTHORIZED_KEYS_SHA256]}" = none ]; then
		echo "root login: no ssh key, the root password locked (no login until the panel gets a key)"
		[ "${GOT[SSH_ACCESS]}" != setup ] || echo "SSH access: setup (the end-user build): sshd is off until the setup page gives root an SSH key (config.d/uc_pxx_ssh.sh); sshd takes keys only (sshd_config.d/00-uc-pxx-key-only.conf)"
	else
		echo "root login: ssh keys only (authorized_keys sha256 ${GOT[AUTHORIZED_KEYS_SHA256]}), the root password locked;" \
			"FOR THE UNITS OF THE KEY OWNER ONLY: never publish this payload for other users"
	fi
	echo "tsx-autoupdate: AUTOUPDATE_MODE=${GOT[AUTOUPDATE_MODE]}$([ "${GOT[AUTOUPDATE_MODE]}" = manual ] && echo " (/etc/tsx/autoupdate.conf MODE=manual, AUTO_RESTART=off: never installs or restarts by itself)")"
	if [ "${GOT[STEP2_BOOTCTL_INST_SHA256]}" = none ]; then
		echo "uc-pxx-bootctl-inst: not in the rootfs (the default build)"
	else
		echo "uc-pxx-bootctl-inst: r2 ${GOT[STEP2_BOOTCTL_INST_SHA256]} and uc-pxx-step2 ${GOT[STEP2_BIN_SHA256]} at /usr/libexec/uc-pxx-step2, the service uc-pxx-step2 ($([ "${GOT[SSH_ACCESS]}" = setup ] && echo "end user: no supervised marker, step 2 may start by itself (AUTO-STEP2)" || echo "supervised: /etc/uc-pxx-step2/supervised")) (a STEP-2 build: for no unit before its RULES line)"
	fi
	if [ "${GOT[XFER_BIN_SHA256]}" = none ]; then echo "the USB set: not in the rootfs"
	else echo "the USB set: uc-pxx-xfer ${GOT[XFER_BIN_SHA256]}, the service uc-pxx-usb (the USB network off by default), /usr/share/uc-pxx-usb/finish.json"; fi
	if [ "$BOTH" = yes ]; then echo "both-slot build: yes (the boot control, slot and data files of $COMMIT; both-slot.txt)"
	else echo "both-slot build: NO (both-slot.txt): a payload for slot A only"; fi
	if [ "${GOT[DEV_APK_KEY_SHA256]}" != none ]; then
		echo "DEV PACKAGES: the uc-pxx packages come from a private build signed by ${DKFILE##*/} (sha256 ${GOT[DEV_APK_KEY_SHA256]}); the image does not trust that key; never publish this payload"
	fi
	sed -n 's/^initramfs_\(sha256\|size\)=/initramfs (built into the Image) \1 /p' "$W/initramfs.info"
	sed -n 's/^program_/initramfs program /p' "$W/initramfs.info"
	echo "the payload folder: $TOTAL bytes ($((TOTAL / 1048576)) MiB); the P10-INSTALL drive: $DRIVE bytes (1200 MiB, FAT):" \
		"$([ $TOTAL -lt $DRIVE ] && echo "fits, $(((DRIVE - TOTAL) / 1048576)) MiB left before the FAT overhead and any other file" || echo "DOES NOT FIT, $(((TOTAL - DRIVE + 1048575) / 1048576)) MiB too large")"
	[ "$rc" = 0 ] || echo "STATUS: OVER THE VBMETA BOOT CAP: the folder is $DIR, not for an install"
	[ -n "$INPUTS" ] || echo "STATUS: DEV BUILD"
} > "$OUT/build-info.txt"
cat "$OUT/build-info.txt"
(cd "$OUT" && sha256sum "$DIR/manifest.json" "$DIR/boot-template.img" "$DIR/rootfs.ext4" inputs.txt rootfs.manifest both-slot.txt > SHA256SUMS)
cat "$OUT/SHA256SUMS"
own_back "$W/pip"
[ "$KEEP" = 1 ] || rm -rf "$W"
step "done: $OUT/$DIR"
exit "$rc"
