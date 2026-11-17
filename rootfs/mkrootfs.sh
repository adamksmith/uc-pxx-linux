#!/bin/sh
# Runs INSIDE an aarch64 Alpine container (see build-rootfs.sh), as root, with
# the repository at /w.
# Env:
#   ALPINE      Alpine branch, for example v3.24
#   KVER        module directory name(s) under /modules/lib/modules, separated
#               by spaces, or empty. The image takes such a tree only when no
#               kernel package has it.
#   OUT         output folder
#   UIDGID      owner of the outputs
#   IMG_MB      ext4 size in MiB (empty: the content plus IMG_HEADROOM_MB)
#   TSX_APK_URL base URL of this project's apk repository. The script writes
#               it into /etc/apk/repositories of the panel and never fetches it.
#   TSX_APK_LOCAL  required: a local copy of the published tree of that
#               repository, <ALPINE>/common and <ALPINE>/uc-pxx. The image
#               installs the profile meta package (uc-pxx-console, uc-pxx-kiosk
#               or uc-pxx-ha) and the packages of packages-tsx.txt from it.
#               check-apk-tree.sh stops the build when the tree lacks one of
#               them, for example the board package uc-pxx-board.
#   AUTHORIZED_KEYS  optional, test builds only
#   TSX_COMMON  optional: a checkout of tsx-linux-common. Its
#               splash/mksplash.sh renders the sizes of UC_PXX_SPLASH_SIZES
#               into /usr/share/tsx/splash (see below)
#   UC_PXX_SPLASH_SIZES  optional: extra splash sizes (WxH, separated by
#               spaces). Empty (the default): only the images of the package
#   TSX_BUILD_ID
#   MIRROR      the Alpine mirror of the build (default dl-cdn.alpinelinux.org).
#               The panel's /etc/apk/repositories always names PANEL_MIRROR
#               (default the same public mirror), never a build snapshot
#   SOURCE_DATE_EPOCH  optional, seconds: a reproducible build (docs/mainline-payload.md).
#               Every file time of the tree is at most this time, the shadow
#               day is this day, the tarball has a fixed order, and mke2fs uses
#               this time. It needs TSX_BUILD_ID and ROOTFS_UUID
#   ROOTFS_UUID optional: the UUID and the directory hash seed of rootfs.ext4
#               (default: random, as mke2fs makes them)
#   TSX_DEV_ROOT_HASH  optional crypt(3) hash that becomes the root password
#               of the image, for our own test builds only. Without it the
#               image has no root password (docs/rootfs.md "Root login").
#   PROFILE     console, kiosk or ha (default ha). It decides what the image
#               holds. profiles/*.list, profile.sh and docs/rootfs.md
#               "Profiles" say what each profile has.
#   UC_PXX_AUTOUPDATE_MODE  optional: manual or auto. manual writes MODE=manual
#               and AUTO_RESTART=off into /etc/tsx/autoupdate.conf (a mainline
#               payload: the slot never installs by itself). Empty or auto: the
#               defaults of tsx-autoupdate (MODE=auto)
#   UC_PXX_SSH_ACCESS  optional: keys or setup. keys: the image has the keys of
#               AUTHORIZED_KEYS (required then) and sshd in the default
#               runlevel. setup (the end-user build; no AUTHORIZED_KEYS): sshd is
#               not in the default runlevel, and the tsx-config plugin
#               rootfs/ssh/uc_pxx_ssh.sh turns it on when the setup page gives
#               root an SSH key. Empty: sshd as the profile says
#   UC_PXX_XFER_BIN  the pinned uc-pxx-xfer (uc-pxx-installer ci/build-xfer.sh,
#               XFER_SHA256 below): the USB set of a both-slot build (the
#               WebUSB interface of every mainline build, docs/usb.md). Without
#               it the build stops when a file of the set is in the image
#   UC_PXX_STEP2_BIN  with UC_PXX_STEP2_BOOTCTL_INST only (required then): the
#               pinned uc-pxx-step2 (uc-pxx-installer ci/build-step2.sh), see
#               the step-2 step below
#   UC_PXX_STEP2_BOOTCTL_INST  optional, off by default: the reviewed static
#               uc-pxx-bootctl-inst r2 (sha256 20aa6bc5...). It goes to
#               /usr/libexec/uc-pxx-step2/uc-pxx-bootctl-inst (root, 0700) for
#               step 2 of the mainline install (MAINLINE-STEP2-DESIGN Q-S8).
#               Without it the build stops when any file of that name is in
#               the image. A step-2 image is for no unit before its RULES line
#   UC_PXX_PROVISION_BIN  optional, with a STEP-2 build of the console
#               profile only: the uc-pxx-provision binary (uc-pxx-installer
#               cmd/uc-pxx-provision) of an R23 BASE build (DESIGN-R23 §3, §7.2).
#               Its sha256 is an input: UC_PXX_PROVISION_SHA256 (required with
#               it). The image then has the provisioning set: the binary at
#               /usr/libexec/uc-pxx-provision/uc-pxx-provision (root, 0700, the
#               folder 0700), the OpenRC service uc-pxx-provision
#               (rootfs/provision/, default runlevel) and its conf, and
#               /usr/share/uc-pxx-provision/ (profile-apply.sh, profile.sh,
#               profiles/, overlay/, profiles.json). rootfs/r23-refs.sh builds
#               the reference trees, their content manifests and the profile
#               bundles from this base, and writes profiles.json. Needs
#               UC_PXX_R23_RELEASE (the release, e.g. 0.2.0-rc10),
#               UC_PXX_PROVISION_URLS (the base URLs of the bundles, separated by
#               spaces) and a local MIRROR (the snapshot). For no unit before
#               its RULES lines
#   UC_PXX_DEV_APK_KEY  TEST ONLY: the public key NAME.rsa.pub of a private
#               build of uc-pxx packages (a local apk tree signed on the build
#               host). It is trusted for the package install only. The image
#               never trusts it: it is removed from $R/etc/apk/keys, and
#               /etc/tsx/dev-apk-key records its name and sha256. Never publish
#               such an image
#   UC_PXX_DEV_OVERLAY  TEST ONLY. 1 builds without the uc-pxx packages
#               (docs/rootfs.md "Test build without the uc-pxx packages"). It
#               needs UC_PXX_BOOTCTL, UC_PXX_REBOOT and RTL8363_INIT (build-rootfs.sh).
#   UC_PXX_DEV_COMMON  TEST ONLY, with UC_PXX_DEV_OVERLAY=1 and TSX_COMMON.
#               1 copies the script files of the TSX_COMMON checkout over the
#               files of the installed common packages, so the image has
#               the common commits that are not published yet.
# The script compiles nothing. It copies only the files of profiles/image.list
# (fstab, inittab, the profile marker) and the splash images of
# UC_PXX_SPLASH_SIZES. The packages own all other files (docs/rootfs.md "Build the image").
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
TOP=$(cd "$HERE/.." && pwd)
R=/build/rootfs; mkdir -p /build
CACHE=/build/pip; mkdir -p $CACHE
MIRROR=${MIRROR:-https://dl-cdn.alpinelinux.org/alpine}
PANEL_MIRROR=${PANEL_MIRROR:-https://dl-cdn.alpinelinux.org/alpine}
SDE=${SOURCE_DATE_EPOCH:-}
if [ -n "$SDE" ]; then
	case $SDE in *[!0-9]*) echo "mkrootfs.sh: SOURCE_DATE_EPOCH=$SDE is not a number of seconds"; exit 1;; esac
	[ -n "${TSX_BUILD_ID:-}" ] || { echo "mkrootfs.sh: SOURCE_DATE_EPOCH needs TSX_BUILD_ID (the build id must not be the build time)"; exit 1; }
	[ -n "${ROOTFS_UUID:-}" ] || { echo "mkrootfs.sh: SOURCE_DATE_EPOCH needs ROOTFS_UUID"; exit 1; }
	export SOURCE_DATE_EPOCH
fi
case ${ROOTFS_UUID:-} in
''|[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]-[0-9a-f][0-9a-f][0-9a-f][0-9a-f]-[0-9a-f][0-9a-f][0-9a-f][0-9a-f]-[0-9a-f][0-9a-f][0-9a-f][0-9a-f]-[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]) ;;
*) echo "mkrootfs.sh: ROOTFS_UUID=$ROOTFS_UUID is not a lower-case UUID"; exit 1;;
esac
ARCH=aarch64
log() { echo "== $*"; }
[ "$(apk --print-arch)" = $ARCH ] || { echo "mkrootfs.sh: this container is $(apk --print-arch), not $ARCH"; exit 1; }

# The profile of the image. has KIND NAME asks the lists in profiles/.
PROFILE=${PROFILE:-ha}
sh "$HERE/profile.sh" includes "$PROFILE" >/dev/null || exit 1
has() { sh "$HERE/profile.sh" has "$PROFILE" "$1" "$2"; }
log "profile $PROFILE"
[ -n "${TSX_APK_LOCAL:-}" ] || { echo "TSX_APK_LOCAL is required (a tsx-aports published tree with $ALPINE/common and $ALPINE/uc-pxx, see rootfs/fetch-apk-tree.sh)"; exit 1; }
DEV=${UC_PXX_DEV_OVERLAY:-}
# The reviewed uc-pxx-bootctl binary (docs/boot-control.md). The DEV mode
# installs only this exact file.
BOOTCTL_SHA256=38fea6d32412e7977ebc5845b138dc1c8c2df8555dae0b64b47f8a851b45e2d7
if [ "$DEV" = 1 ]; then
	log "TEST BUILD (UC_PXX_DEV_OVERLAY=1): no uc-pxx packages, the repository files instead. Never publish this image."
	[ -r "${UC_PXX_BOOTCTL:-}" ] || { echo "UC_PXX_DEV_OVERLAY=1: no UC_PXX_BOOTCTL"; exit 1; }
	[ -r "${UC_PXX_REBOOT:-}" ] || { echo "UC_PXX_DEV_OVERLAY=1: no UC_PXX_REBOOT"; exit 1; }
	[ -r "${RTL8363_INIT:-}" ] || { echo "UC_PXX_DEV_OVERLAY=1: no RTL8363_INIT"; exit 1; }
	sum=$(sha256sum "$UC_PXX_BOOTCTL" | cut -d' ' -f1)
	[ "$sum" = "$BOOTCTL_SHA256" ] || { echo "ERROR: UC_PXX_BOOTCTL has sha256 $sum, the reviewed binary is $BOOTCTL_SHA256"; exit 1; }
	log "uc-pxx-bootctl: sha256 $sum (the reviewed binary)"
else
	log "build from packages: uc-pxx-$PROFILE"
fi

printf '%s/%s/main\n%s/%s/community\n' "$MIRROR" "$ALPINE" "$MIRROR" "$ALPINE" > /etc/apk/repositories
apk update -q

# This project's apk repository (tsx-aports). The panel lists it first in
# /etc/apk/repositories at TSX_APK_URL (panel.conf APK_URL overrides that on
# the panel, tsx-config apply). The image gets the packages of the repository
# (the meta package and packages-tsx.txt) only from a LOCAL copy of the
# published tree (TSX_APK_LOCAL): the build never depends on TSX_APK_URL being
# reachable.
TSX_APK_URL=${TSX_APK_URL:-https://tsx-aports.unexceptional.net}; TSX_APK_URL=${TSX_APK_URL%/}
# The DEV mode uses only the common category.
TSX_CATS="common uc-pxx"; [ "$DEV" = 1 ] && TSX_CATS=common
for c in $TSX_CATS; do
	[ -r "$TSX_APK_LOCAL/$ALPINE/$c/$ARCH/APKINDEX.tar.gz" ] || { echo "TSX_APK_LOCAL: no $ALPINE/$c/$ARCH/APKINDEX.tar.gz under $TSX_APK_LOCAL"; exit 1; }
done
# The board package and the meta packages are not in the public tree. Stop here
# with a clear message when the tree lacks one of them.
if [ "$DEV" != 1 ]; then
	sh "$HERE/check-apk-tree.sh" "$TSX_APK_LOCAL" "$PROFILE" || { echo "ERROR: the tree $TSX_APK_LOCAL lacks packages that the $PROFILE image needs (docs/rootfs.md \"Where the packages come from\")"; exit 1; }
fi
apk add -q --no-cache e2fsprogs tar gzip zstd coreutils findutils >/dev/null

log "install packages ($ALPINE, $ARCH)"
rm -rf $R; mkdir -p $R/etc/apk/keys
# trust this project's signing key (the same .pub the tsx-keys package ships)
cp "$HERE"/overlay/etc/apk/keys/*.rsa.pub /etc/apk/keys/
cp -a /etc/apk/keys/. $R/etc/apk/keys/
# A private package build (TEST ONLY): its key for the install, never in the image
DEVKEY=
if [ -n "${UC_PXX_DEV_APK_KEY:-}" ]; then
	DEVKEY=${UC_PXX_DEV_APK_KEY##*/}
	case $DEVKEY in *[!A-Za-z0-9._-]*|.*) echo "UC_PXX_DEV_APK_KEY: a bad file name"; exit 1;; *.rsa.pub) ;; *) echo "UC_PXX_DEV_APK_KEY: the name must end in .rsa.pub"; exit 1;; esac
	for k in "$HERE"/overlay/etc/apk/keys/*.rsa.pub /etc/apk/keys/*; do
		[ "${k##*/}" != "$DEVKEY" ] || { echo "UC_PXX_DEV_APK_KEY has the name of a trusted key (${k##*/})"; exit 1; }
	done
	cp "$UC_PXX_DEV_APK_KEY" /etc/apk/keys/"$DEVKEY"
	DEVKEY_SHA=$(sha256sum "$UC_PXX_DEV_APK_KEY" | cut -d' ' -f1)
	log "TEST BUILD (UC_PXX_DEV_APK_KEY): packages signed by $DEVKEY ($DEVKEY_SHA) are trusted for this install only"
fi
# The profile picks the packages (profiles/*.list). The lines keep the order
# of packages.txt and packages-tsx.txt. profile_pkgs PROFILE: the names that
# `apk add` gets for that profile (the R23 references use it for the other
# profiles, rootfs/r23-refs.sh).
profile_pkgs() {
	_a=$(sh "$HERE/profile.sh" packages "$1" "$HERE/packages.txt" | tr '\n' ' ')
	_t=$(sh "$HERE/profile.sh" packages "$1" "$HERE/packages-tsx.txt" | tr '\n' ' ')
	# The profile meta package pulls the packages that hold the panel software.
	if [ "$DEV" = 1 ]; then
		# no uc-pxx packages: the common packages that the meta package will pull
		_t=$(printf '%s\n' $_t | grep -v '^uc-pxx-' | tr '\n' ' ')
		for l in $(sh "$HERE/profile.sh" includes "$1"); do
			_t="$_t $(awk -v p="$l" '$1 == p { print $2 }' "$HERE/dev/common-packages.list" | tr '\n' ' ')"
		done
	else
		_t="$_t uc-pxx-$1"
	fi
	# uc-pxx-chromium (if listed) provides chromium, so Alpine chromium stays out
	if printf '%s\n' $_t | grep -qx uc-pxx-chromium; then
		_a=$(sh "$HERE/profile.sh" packages "$1" "$HERE/packages.txt" | grep -vx chromium | tr '\n' ' ')
	fi
	echo $_a $_t
}
PKGS=$(profile_pkgs "$PROFILE")
log "packages: $PKGS"
: > /build/repositories
for c in $TSX_CATS; do printf '%s/%s/%s\n' "$TSX_APK_LOCAL" "$ALPINE" "$c" >> /build/repositories; done
cat /etc/apk/repositories >> /build/repositories
apk add --root $R --initdb --no-cache -q --keys-dir /etc/apk/keys \
	--repositories-file /build/repositories $PKGS
cp -a /etc/apk/keys $R/etc/apk/
if [ -n "$DEVKEY" ]; then
	rm -f "$R/etc/apk/keys/$DEVKEY"
	mkdir -p $R/etc/tsx
	echo "TEST BUILD: the uc-pxx packages of this image come from a private build, signed by $DEVKEY (sha256 $DEVKEY_SHA). The image does not trust that key. tsx-autoupdate starts in manual mode. Never publish this image." > $R/etc/tsx/dev-apk-key
	# Such an image must not update itself from the channel (review m4): its
	# boot control is not the published one. MODE=manual in the user file;
	# a person may change it on the panel.
	A=$R/etc/tsx/autoupdate.conf
	if [ -f "$A" ] && grep -q '^MODE=' "$A"; then sed -i 's/^MODE=.*/MODE=manual/' "$A"
	else printf '%s\n' '# DEV PACKAGES (mkrootfs.sh UC_PXX_DEV_APK_KEY): never install by itself' 'MODE=manual' >> "$A"; fi
	log "TEST BUILD: tsx-autoupdate MODE=manual in /etc/tsx/autoupdate.conf"
fi
# The tsx-autoupdate mode of a mainline payload (UC_PXX_AUTOUPDATE_MODE; the
# RC-5 release review MINOR-2): manual = the slot never installs by itself. A
# person installs from Home Assistant or with `tsx-autoupdate now`. Such an
# install does not restart the unit (AUTO_RESTART=off, owner 2026-11-12, the RC-6
# code review MINOR-5): Home Assistant shows "Restart required", and the person
# picks the time of the restart into the new boot image. UPDATE_MODE and
# UPDATE_AUTO_RESTART of panel.conf (the setup page, Home Assistant) still win
# over this file.
case "${UC_PXX_AUTOUPDATE_MODE:-}" in
''|auto) ;;
manual)
	A=$R/etc/tsx/autoupdate.conf
	mkdir -p $R/etc/tsx
	[ ! -L "$A" ] || { echo "ERROR: $A is a link"; exit 1; }
	if [ -f "$A" ]; then sed -i -e '/^MODE=/d' -e '/^AUTO_RESTART=/d' "$A"; fi
	printf '%s\n' '# the default of this mainline build (tools/mainline-payload/build.sh AUTOUPDATE_MODE=manual):' \
		'# never install by itself; a person restarts after an install' 'MODE=manual' 'AUTO_RESTART=off' >> "$A"
	chmod 644 "$A"
	[ "$(grep -c '^MODE=' "$A")" = 1 ] && [ "$(grep -c '^AUTO_RESTART=' "$A")" = 1 ] && grep -qx 'MODE=manual' "$A" &&
		grep -qx 'AUTO_RESTART=off' "$A" ||
		{ echo "ERROR: /etc/tsx/autoupdate.conf does not say MODE=manual and AUTO_RESTART=off once"; exit 1; }
	log "tsx-autoupdate: MODE=manual, AUTO_RESTART=off in /etc/tsx/autoupdate.conf (UC_PXX_AUTOUPDATE_MODE)";;
*) echo "ERROR: UC_PXX_AUTOUPDATE_MODE='$UC_PXX_AUTOUPDATE_MODE' is not manual or auto"; exit 1;;
esac
# the panel's list: this project's two repositories FIRST (common + uc-pxx,
# never another platform's). The block, marker line included, is what
# tsx-config apply writes.
{
	echo "# tsx-aports (tsx-config apply; panel.conf APK_URL)"
	echo "$TSX_APK_URL/$ALPINE/common"
	echo "$TSX_APK_URL/$ALPINE/uc-pxx"
	printf '%s/%s/main\n%s/%s/community\n' "$PANEL_MIRROR" "$ALPINE" "$PANEL_MIRROR" "$ALPINE"
} > $R/etc/apk/repositories

if [ "$DEV" = 1 ]; then
	# TEST ONLY: the files that the packages uc-pxx-board, uc-pxx-leds and
	# uc-pxx-boot-tools will own, straight from the repository
	if [ "${UC_PXX_DEV_COMMON:-}" = 1 ]; then
		# TEST ONLY: the common checkout over the published common packages.
		# Each folder of tsx-linux-common is the root of one package (the
		# APKBUILDs of tsx-aports). Only the folders of installed packages
		# count, and in them only etc/ and usr/ (the other folders are
		# sources). The compiled programs stay as packaged. The board files
		# below win over these files.
		[ -d "${TSX_COMMON:-}/base" ] || { echo "UC_PXX_DEV_COMMON=1 needs TSX_COMMON"; exit 1; }
		log "DEV: common files from TSX_COMMON over the packages"
		: > /build/dev-common.list
		for m in base:tsx-base autoupdate:tsx-autoupdate buttons:tsx-buttons kiosk:tsx-kiosk setup:tsx-setup \
			ha:tsx-ha panel-app:tsx-panel-app sendspin:tsx-sendspin rescue:tsx-rescue-ui; do
			d=${m%%:*} pkg=${m#*:}
			[ -d "$TSX_COMMON/$d" ] && apk info --root $R -e "$pkg" > /dev/null 2>&1 || continue
			(cd "$TSX_COMMON/$d" && find ./etc ./usr -type f 2>/dev/null) |
			while read -r f; do
				t=${f#./}
				cmp -s "$TSX_COMMON/$d/$t" "$R/$t" && continue
				[ -e "$R/$t" ] && why=changed || why=new
				install -D -m "$(stat -c %a "$TSX_COMMON/$d/$t")" -o 0 -g 0 "$TSX_COMMON/$d/$t" "$R/$t"
				chmod go-w "$R/$t"
				echo "$why $pkg /$t" | tee -a /build/dev-common.list
			done
		done
		# tsx-ha installs the ESPHome shim in /opt/lva/shim (install-lva.sh
		# below copies it from there)
		if apk info --root $R -e tsx-ha > /dev/null 2>&1 && [ -d "$TSX_COMMON/ha/voice/shim" ]; then
			(cd "$TSX_COMMON/ha/voice/shim" && find . -type f -name '*.py') | while read -r f; do
				t=opt/lva/shim/${f#./}
				cmp -s "$TSX_COMMON/ha/voice/shim/$f" "$R/$t" && continue
				[ -e "$R/$t" ] && why=changed || why=new
				install -D -m 644 -o 0 -g 0 "$TSX_COMMON/ha/voice/shim/$f" "$R/$t"
				echo "$why tsx-ha /$t" | tee -a /build/dev-common.list
			done
		fi
		mkdir -p $R/etc/tsx
		{ echo "TEST BUILD (UC_PXX_DEV_COMMON=1): these files come from a tsx-linux-common checkout, not from the packages."
		  cat /build/dev-common.list; } > $R/etc/tsx/dev-common-overlay
	fi
	log "DEV: rootfs/overlay, packages/uc-pxx-leds/root, uc-pxx-bootctl, rtl8363-init"
	for d in "$HERE/overlay" "$TOP/packages/uc-pxx-leds/root"; do
		(cd "$d" && tar --owner=0 --group=0 --numeric-owner -cf - .) | tar -C $R -xpf -
		# fixed modes, whatever the umask of the checkout
		sh "$HERE/profile.sh" modes "$d" $R
	done
	install -m 755 -o 0 -g 0 "$UC_PXX_BOOTCTL" $R/usr/sbin/uc-pxx-bootctl
	install -m 755 -o 0 -g 0 "$RTL8363_INIT" $R/usr/sbin/rtl8363-init
	# the last step of uc-pxx-reboot (the script comes with rootfs/overlay)
	install -D -m 755 -o 0 -g 0 "$UC_PXX_REBOOT" $R/usr/libexec/uc-pxx-reboot-syscall
	[ "$(sha256sum $R/usr/sbin/uc-pxx-bootctl | cut -d' ' -f1)" = "$BOOTCTL_SHA256" ] || { echo "ERROR: uc-pxx-bootctl changed in the copy"; exit 1; }
	mkdir -p $R/etc/tsx
	echo "TEST BUILD (UC_PXX_DEV_OVERLAY=1), not from the uc-pxx packages. Do not publish." > $R/etc/tsx/dev-overlay
fi

# The splash images (docs/boot.md "The boot splash"). The package tsx-splash
# has images up to 1280x800. tsx-splash draws the largest image that fits,
# centered, on the 1920x1200 screen of the UC-P10: a full "show" after the
# orientation changed, and the background of the kiosk (tsx-splash png). The
# kiosk scale is 1.5, so the 1280x800 image has the physical size of the
# TSW 10" panels. UC_PXX_SPLASH_SIZES adds other sizes (WxH, separated by
# spaces) with mksplash.sh of tsx-linux-common. It is empty by default.
if [ -d $R/usr/share/tsx/splash ] && [ -n "${UC_PXX_SPLASH_SIZES:-}" ]; then
	[ -n "${TSX_COMMON:-}" ] || { echo "ERROR: UC_PXX_SPLASH_SIZES needs TSX_COMMON"; exit 1; }
	log "splash images $UC_PXX_SPLASH_SIZES (mksplash.sh of tsx-linux-common)"
	sh "$TSX_COMMON/splash/mksplash.sh" /build/board-splash $UC_PXX_SPLASH_SIZES > /dev/null
	for sz in $UC_PXX_SPLASH_SIZES; do
		install -m 644 -o 0 -g 0 /build/board-splash/splash-$sz.ppm $R/usr/share/tsx/splash/
	done
	rm -rf /build/board-splash
fi

# The profile steps (DESIGN-R23 §3.5): rootfs/profile-apply.sh, the same
# script that the R23 references and the unit (uc-pxx-provision) run after
# their own package install. It runs in the tree under chroot, with the tools
# of the tree: /opt/lva of the ha profile (rootfs/lva-build.sh: install-lva.sh
# of the package tsx-ha, packed into a reproducible lva.tar), the owner of
# /etc and /usr/local, the shared library check, the users, the hostname, the
# trim, the fontconfig caches, the files of profiles/image.list (fstab,
# inittab, the profile marker; the packages own all other files) and the
# services of the profile.
LVAARG=
if has step lva; then
	log "Home Assistant device (tsx-esphome) and voice satellite (linux-voice-assistant)"
	sh "$HERE/lva-build.sh" $R /build/lva.tar
	LVAARG="--lva /build/lva.tar"
fi
log "the profile steps ($PROFILE)"
# shellcheck disable=SC2086 # empty or two words
sh "$HERE/profile-apply.sh" "$PROFILE" $R $LVAARG
if [ "$DEV" = 1 ]; then
	# The published tsx-autoupdate has no board hook. An update must arm slot A
	# first (uc-pxx-arm-slot, docs/boot-control.md "The update rule"). So a
	# DEV image does not start it.
	rm -f $R/etc/runlevels/default/tsx-autoupdate
	log "DEV: tsx-autoupdate is not started (no board hook in the published common packages)"
fi
# The fstab of this repository has no /data line (review F7): the service
# uc-pxx-lvm of the package uc-pxx-board mounts /data by device (its line
# "# uc-pxx-data-mount: 1"). An older package only activates the LVM volume
# group and relies on the fstab. Then the image gets the old /data line back,
# so it mounts /data as before; such an image is not a both-slot build, and
# step 2 (uc-pxx-data-migrate) refuses a running fstab with LABEL= (review
# R1-1 of MAINLINE-LINUX-INT-REVIEW-1.md).
if [ -e $R/etc/init.d/uc-pxx-lvm ] && ! grep -qx '# uc-pxx-data-mount: 1' $R/etc/init.d/uc-pxx-lvm; then
	if ! grep -v '^[[:space:]]*#' $R/etc/fstab | awk '$2 == "/data"' | grep -q .; then
		printf '%s\n' '# added by mkrootfs.sh: the uc-pxx-lvm of this image does not mount /data itself (an older uc-pxx-board)' \
			'LABEL=tsxdata   /data         ext4    rw,noatime,commit=60,nofail 0      0' >> $R/etc/fstab
		log "WARNING: the package uc-pxx-lvm does not mount /data: the fstab gets the old LABEL=tsxdata line (not a both-slot image)"
	fi
fi
# (end of the fstab step)
mkdir -p $R/data   # the data partition's mount point (fstab, tsx-data)
# The state folder of the tsx tools (tsx-linux-common): tsx-autoupdate,
# tsx-config, the panel app. No package ships it: tsx-data makes it (and binds
# /data/var/lib/tsx onto it) only in a boot that has /data. A boot without
# /data (a slot that the RAM installer wrote, before step 2: uc-pxx-lvm leaves
# /data a folder of the root file system) needs it on the root file system:
# the start of tsx-autoupdate (`checkpath -d /var/lib/tsx/autoupdate`) makes
# no parent folder, and without its state folder step 2 refuses (its hold
# check: U2-5, 2026-11-14). With /data, tsx-data sees the same empty folder
# that its own `mkdir -p` made before. Root, 0755, empty.
mkdir -p $R/var/lib/tsx && chown 0:0 $R/var/lib/tsx && chmod 0755 $R/var/lib/tsx
# the build's repository URL: tsx-config apply falls back to it when
# panel.conf has no APK_URL
printf '%s\n' "$TSX_APK_URL" > $R/etc/tsx/apk-url.default
# build id for tsx-autoupdate / the HA update entity (installed_version)
printf '%s\n' "${TSX_BUILD_ID:-$(date -u +%Y%m%d%H%M)}" > $R/etc/tsx/build-id
# The floor of the boot clock. The service hwclock sets the clock from the
# RTC of the RK808. The RTC keeps the time over a reboot, but it has no backup
# battery and reads a date in 2013 after a power cut. Then uc-pxx-clock sets
# the clock to the mtime of this file and writes the RTC. So a new image never
# boots earlier than its build time (/etc/periodic/15min/tsx-savetime keeps
# the file current while NTP has the time)
mkdir -p $R/var/lib/misc && touch $R/var/lib/misc/openrc-shutdowntime
log "crontab, sshd"
chroot $R /bin/sh -e <<'CH'
mkdir -p /etc/crontabs && touch /etc/crontabs/root
# ssh: root with password or key (change on deploy, panel.conf
# ROOT_PASSWORD_HASH / SSH_AUTHORIZED_KEY)
sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config
# allow ssh -L (DevTools tunnel for the first HA login). Alpine ships "no"
sed -i 's/^AllowTcpForwarding.*/AllowTcpForwarding local/' /etc/ssh/sshd_config
grep -q '^PermitRootLogin' /etc/ssh/sshd_config || echo 'PermitRootLogin yes' >> /etc/ssh/sshd_config
CH
# Root password (docs/rootfs.md "Root login"). A public image has none: the
# field in /etc/shadow is locked ("*"), never empty. The installer stops unless
# it gets a root password or an SSH key. It puts the hash of the password and
# the key in panel.conf, and the first boot applies them (tsx-config apply).
# With a key only, the password stays locked until a person sets one over ssh.
# Only a test build sets a fixed password: TSX_DEV_ROOT_HASH, a crypt(3) hash.
if [ -n "${TSX_DEV_ROOT_HASH:-}" ]; then
	case "$TSX_DEV_ROOT_HASH" in \$6\$*) ;; *) echo "TSX_DEV_ROOT_HASH is not a sha-512 crypt hash (\$6\$...)"; exit 1;; esac
	sed -i "s|^root:[^:]*:|root:$TSX_DEV_ROOT_HASH:|" $R/etc/shadow
	ROOT_PW_RESULT="TSX_DEV_ROOT_HASH (test build, do not publish)"
else
	sed -i "s|^root:[^:]*:|root:*:|" $R/etc/shadow
	ROOT_PW_RESULT="none (locked until the installer or ssh sets one)"
fi
echo "root password: $ROOT_PW_RESULT"
# AUTHORIZED_KEYS (optional) bakes a key into the image. It is a test option.
if [ -n "${AUTHORIZED_KEYS:-}" ] && [ -s "$AUTHORIZED_KEYS" ]; then
	mkdir -p $R/root/.ssh; cp "$AUTHORIZED_KEYS" $R/root/.ssh/authorized_keys; chmod 700 $R/root/.ssh; chmod 600 $R/root/.ssh/authorized_keys
fi

log "trim"
# /etc/machine-id: the dbus package's post-install trigger writes one id
# into the image, which every panel flashed from it would then share. Ship it
# empty: OpenRC's machine-id service (boot runlevel) fills an empty one once,
# on each unit's first boot.
: > $R/etc/machine-id
# (the rest of the trim is a profile step: profile-apply.sh)

# Kernel modules. The kernel packages own the trees in /lib/modules. A release
# build (.github/workflows/release.yml) also stages the modules of the kernel
# that it builds, and the build copies such a tree when no package has it.
copied=0
for kv in ${KVER:-}; do
	if [ -d "$R/lib/modules/$kv" ]; then
		# installed (and owned) by uc-pxx-kernel-<flavor>: keep the package's tree
		log "kernel modules $kv: from its uc-pxx-kernel package"
		copied=$((copied + 1))
	elif [ -d "/modules/lib/modules/$kv" ]; then
		echo "WARNING: kernel modules $kv: no uc-pxx-kernel package in $TSX_APK_LOCAL has them, so they are copied as unowned files"
		log "kernel modules $kv"
		mkdir -p $R/lib/modules
		cp -a "/modules/lib/modules/$kv" $R/lib/modules/
		rm -f "$R/lib/modules/$kv/build" "$R/lib/modules/$kv/source"
		depmod -b $R "$kv" 2>/dev/null || true
		copied=$((copied + 1))
	else
		echo "WARNING: no modules for $kv at /modules/lib/modules/$kv"
	fi
done
if [ "$copied" -gt 0 ]; then
	chown -R 0:0 $R/lib/modules
else
	log "no kernel modules staged (KVER=${KVER:-unset}), the kernel package has them"
fi

# The kernel package must carry the pinned kernel (kernel/KERNEL_REV.lts). An
# old package in the local tree would put a stale /boot/uc-pxx-lts.img in the
# image.
if [ "$DEV" = 1 ]; then
	# no kernel package: the boot image comes from the kernel build directly
	short=$(grep -v '^#' "$TOP/kernel/KERNEL_REV.lts" | head -n 1 | cut -c1-12)
	for kv in $(ls $R/lib/modules 2>/dev/null); do
		case $kv in *-g"$short") ;; *) echo "ERROR: the module tree $kv is not from the pinned kernel $short"; exit 1;; esac
	done
	log "DEV: no kernel package, module trees: $(ls $R/lib/modules 2>/dev/null | tr '\n' ' ')"
else
	log "check the kernel package against kernel/KERNEL_REV.lts"
	sh "$HERE/check-kernel-pins.sh" "$R" "$TOP/kernel" || { echo "ERROR: the kernel package in $TSX_APK_LOCAL does not match the kernel pin"; exit 1; }
fi

# The SSH access of a mainline payload (UC_PXX_SSH_ACCESS; owner 2026-11-12,
# docs/mainline-payload.md "SSH access"):
#   keys   the maintainer build: AUTHORIZED_KEYS is required, sshd stays in the
#          default runlevel (as before)
#   setup  the end-user build: no AUTHORIZED_KEYS (no /root/.ssh), sshd is not
#          in the default runlevel, and the tsx-config plugin
#          /usr/local/lib/tsx/config.d/uc_pxx_ssh.sh (root, 0644, the folder
#          0755) turns sshd on when the setup page gives root an SSH key.
#          sshd takes keys only: /etc/ssh/sshd_config.d/00-uc-pxx-key-only.conf
#          (PasswordAuthentication no, KbdInteractiveAuthentication no; it sorts
#          before tsx.conf of tsx-base, and sshd keeps the first value). A root
#          password of the setup page is for the console only.
UC_PXX_SSH_PLUGIN=usr/local/lib/tsx/config.d/uc_pxx_ssh.sh
case "${UC_PXX_SSH_ACCESS:-}" in
'') [ ! -e "$R/$UC_PXX_SSH_PLUGIN" ] || { echo "ERROR: the image has $UC_PXX_SSH_PLUGIN without UC_PXX_SSH_ACCESS=setup"; exit 1; };;
keys)
	[ -s $R/root/.ssh/authorized_keys ] || { echo "ERROR: UC_PXX_SSH_ACCESS=keys needs AUTHORIZED_KEYS"; exit 1; }
	[ -L $R/etc/runlevels/default/sshd ] || { echo "ERROR: UC_PXX_SSH_ACCESS=keys: sshd is not in the default runlevel"; exit 1; }
	[ ! -e "$R/$UC_PXX_SSH_PLUGIN" ] || { echo "ERROR: UC_PXX_SSH_ACCESS=keys: the image has $UC_PXX_SSH_PLUGIN"; exit 1; }
	[ ! -e $R/etc/ssh/sshd_config.d/00-uc-pxx-key-only.conf ] || { echo "ERROR: UC_PXX_SSH_ACCESS=keys: the image has the end-user key-only rule"; exit 1; }
	log "SSH access: keys (the keys of AUTHORIZED_KEYS, sshd in the default runlevel)";;
setup)
	[ ! -e $R/root/.ssh ] || { echo "ERROR: UC_PXX_SSH_ACCESS=setup: the image has /root/.ssh"; exit 1; }
	[ -L $R/etc/runlevels/default/sshd ] || { echo "ERROR: UC_PXX_SSH_ACCESS=setup: the profile has no sshd in the default runlevel"; exit 1; }
	rm -f $R/etc/runlevels/default/sshd
	[ -e $R/etc/init.d/sshd ] || { echo "ERROR: UC_PXX_SSH_ACCESS=setup: no /etc/init.d/sshd"; exit 1; }
	install -d -m 755 -o 0 -g 0 $R/usr/local/lib/tsx/config.d
	install -m 644 -o 0 -g 0 "$HERE/ssh/uc_pxx_ssh.sh" "$R/$UC_PXX_SSH_PLUGIN"
	install -d -m 755 -o 0 -g 0 $R/etc/ssh/sshd_config.d
	install -m 644 -o 0 -g 0 "$HERE/ssh/00-uc-pxx-key-only.conf" $R/etc/ssh/sshd_config.d/00-uc-pxx-key-only.conf
	grep -q '^Include /etc/ssh/sshd_config.d/\*\.conf' $R/etc/ssh/sshd_config ||
		{ echo "ERROR: /etc/ssh/sshd_config does not include sshd_config.d (the key-only rule of the end-user build)"; exit 1; }
	[ "$(cd $R/etc/ssh/sshd_config.d && ls | head -n 1)" = 00-uc-pxx-key-only.conf ] ||
		{ echo "ERROR: 00-uc-pxx-key-only.conf is not the first file of sshd_config.d"; exit 1; }
	[ -z "$(find $R/etc/runlevels -name sshd)" ] || { echo "ERROR: UC_PXX_SSH_ACCESS=setup: sshd is still in a runlevel"; exit 1; }
	log "SSH access: setup (no key, sshd off until the setup page gives root an SSH key: $UC_PXX_SSH_PLUGIN; keys only)";;
*) echo "ERROR: UC_PXX_SSH_ACCESS='$UC_PXX_SSH_ACCESS' is not keys or setup"; exit 1;;
esac

# The USB set (uc-pxx-installer mainline-rc-4; owner decisions 2026-11-11,
# docs/usb.md): every both-slot build (normal and STEP-2) brings up the WebUSB
# vendor interface of uc-pxx-xfer on its USB-C port. UC_PXX_XFER_BIN (the
# pinned uc-pxx-xfer, uc-pxx-installer ci/build-xfer.sh) adds:
#   /usr/libexec/uc-pxx-xfer/uc-pxx-xfer (root, 0755: the receiver runs it as
#     the user uc-pxx-xfer), the OpenRC service uc-pxx-usb (default runlevel)
#     and its conf file (UC_PXX_USB_NET=off: the USB network + ssh setting),
#   /usr/share/uc-pxx-usb/finish.json (the slot's pinned finish set: the finish
#     executor uc-pxx-step2-finish and uc-pxx-bootctl-inst r2 by size and
#     sha256; neither file is in the image),
#   /etc/ssh/sshd_config.d/uc-pxx-usb.conf (ssh by key only on the USB network),
#   the system user and group uc-pxx-xfer (uid and gid 990, no shell, no home,
#     no other group).
# Never a serial console (no getty on ttyGS*) and no other gadget function.
# Only for a both-slot image (uc-pxx-lvm mounts /data itself); the installer's
# both-slot gate pins each of these files (internal/mainline bothSlotUSB) and
# refuses them in a slot-A payload. Without UC_PXX_XFER_BIN no file of these
# names may be in the image.
# uc-pxx-xfer 62421c48... of uc-pxx-installer mainline-rc-10 fd90ed4 (the
# kinds step1, consent and provision; ci/build-xfer.sh, twice byte-identical;
# its bytes depend on no gate data). Earlier: 42d764e0... (RC-5 to RC-9).
XFER_SHA256=62421c487cf0233d1cee2844f623bf4de120a3ec7daa599bfb6f6465d6fe5d60
XFER_PATH=usr/libexec/uc-pxx-xfer/uc-pxx-xfer
XFER_ID=990
USB_FILES="etc/conf.d/uc-pxx-usb etc/init.d/uc-pxx-usb etc/runlevels/default/uc-pxx-usb etc/ssh/sshd_config.d/uc-pxx-usb.conf usr/libexec/uc-pxx-xfer usr/libexec/uc-pxx-xfer/uc-pxx-xfer usr/share/uc-pxx-usb "
if [ -n "${UC_PXX_XFER_BIN:-}" ]; then
	sum=$(sha256sum "$UC_PXX_XFER_BIN" | cut -d' ' -f1)
	[ "$sum" = "$XFER_SHA256" ] || { echo "ERROR: UC_PXX_XFER_BIN has sha256 $sum, the pinned uc-pxx-xfer is $XFER_SHA256"; exit 1; }
	[ -e $R/etc/init.d/uc-pxx-lvm ] && grep -qx '# uc-pxx-data-mount: 1' $R/etc/init.d/uc-pxx-lvm ||
		{ echo "ERROR: the USB set (UC_PXX_XFER_BIN) is for a both-slot image only (uc-pxx-lvm must mount /data)"; exit 1; }
	! grep -q "^[^:]*:[^:]*:$XFER_ID:" $R/etc/passwd && ! grep -q "^[^:]*:[^:]*:$XFER_ID:" $R/etc/group &&
		! grep -q '^uc-pxx-xfer:' $R/etc/passwd $R/etc/group ||
		{ echo "ERROR: uid/gid $XFER_ID or the name uc-pxx-xfer is taken in the image"; exit 1; }
	echo "uc-pxx-xfer:x:$XFER_ID:$XFER_ID:uc-pxx USB receiver:/nonexistent:/sbin/nologin" >> $R/etc/passwd
	echo "uc-pxx-xfer:x:$XFER_ID:" >> $R/etc/group
	echo "uc-pxx-xfer:!:::::::" >> $R/etc/shadow
	install -d -m 755 -o 0 -g 0 $R/usr/libexec/uc-pxx-xfer $R/usr/share/uc-pxx-usb $R/etc/ssh/sshd_config.d
	install -m 755 -o 0 -g 0 "$UC_PXX_XFER_BIN" "$R/$XFER_PATH"
	[ "$(sha256sum "$R/$XFER_PATH" | cut -d' ' -f1)" = "$XFER_SHA256" ] || { echo "ERROR: uc-pxx-xfer changed in the copy"; exit 1; }
	install -m 755 -o 0 -g 0 "$HERE/usb/init.d/uc-pxx-usb" $R/etc/init.d/uc-pxx-usb
	install -m 644 -o 0 -g 0 "$HERE/usb/conf.d/uc-pxx-usb" $R/etc/conf.d/uc-pxx-usb
	install -m 644 -o 0 -g 0 "$HERE/usb/finish.json" $R/usr/share/uc-pxx-usb/finish.json
	install -m 644 -o 0 -g 0 "$HERE/usb/sshd_config.d/uc-pxx-usb.conf" $R/etc/ssh/sshd_config.d/uc-pxx-usb.conf
	ln -sf /etc/init.d/uc-pxx-usb $R/etc/runlevels/default/uc-pxx-usb
	grep -q '^Include /etc/ssh/sshd_config.d/\*\.conf' $R/etc/ssh/sshd_config ||
		{ echo "ERROR: /etc/ssh/sshd_config does not include sshd_config.d (the key-only rule of the USB network)"; exit 1; }
	grep -qx 'UC_PXX_USB_NET=off' $R/etc/conf.d/uc-pxx-usb || { echo "ERROR: the USB network setting is not off by default"; exit 1; }
	log "the USB set: uc-pxx-xfer $XFER_SHA256, the service uc-pxx-usb (the USB network off), the finish list, the user uc-pxx-xfer ($XFER_ID)"
fi
usb=$(cd $R && find . \( -name 'uc-pxx-xfer*' -o -name 'uc-pxx-usb*' \) | sed 's#^\./##' | sort | tr '\n' ' ')
if [ -n "${UC_PXX_XFER_BIN:-}" ]; then
	[ "$usb" = "$USB_FILES" ] || { echo "ERROR: the USB set in the image is '$usb', not exactly '$USB_FILES'"; exit 1; }
else
	[ -z "$usb" ] || { echo "ERROR: the image has files of the USB set ($usb) without UC_PXX_XFER_BIN"; exit 1; }
fi
# no serial console on the USB port, ever (owner 2026-11-11)
! grep -v '^[[:space:]]*#' $R/etc/inittab | grep -q 'ttyGS' || { echo "ERROR: /etc/inittab has a getty on a USB serial gadget (ttyGS*)"; exit 1; }

# uc-pxx-bootctl-inst in the root file system (MAINLINE-STEP2-DESIGN Q-S8,
# §12 R-F item 3). RULES.md today: the two-slot A/B tool is never in system_a,
# boot_a or a package. So by default (UC_PXX_STEP2_BOOTCTL_INST empty) the
# image has no file of that name anywhere, and no file of step 2 at all
# (uc-pxx-step2*): the build stops if a package brought one.
# UC_PXX_STEP2_BOOTCTL_INST (a separate build option, off by default) makes a
# STEP-2 BUILD (MAINLINE-STEP2-REST §6 item 2, L9): exactly the reviewed r2
# binary 20aa6bc5... at /usr/libexec/uc-pxx-step2/uc-pxx-bootctl-inst and the
# pinned uc-pxx-step2 (UC_PXX_STEP2_BIN, required with it) at
# /usr/libexec/uc-pxx-step2/uc-pxx-step2 (root, 0700, the folder 0700), the
# OpenRC service uc-pxx-step2 (rootfs/step2/, in the default runlevel; it
# starts `uc-pxx-step2 service` in the background) and its conf file. The kind
# of the STEP-2 build follows the SSH access (uc-pxx-linux rc-payload-7, owner
# Q-T5 2026-11-12): a SUPERVISED STEP-2 build (UC_PXX_SSH_ACCESS keys or empty:
# the maintainer's key) has the supervised marker /etc/uc-pxx-step2/supervised
# (the service then never writes or counts down by itself); an END-USER STEP-2
# build (UC_PXX_SSH_ACCESS=setup: no ssh key) has no /etc/uc-pxx-step2 at all
# (its step 2 may start by itself, AUTO-STEP2, and installs only an end-user
# payload). The marker /etc/tsx/step2-bootctl-inst says which. The data tool of step 2 is
# /usr/sbin/uc-pxx-data-migrate of uc-pxx-board (pinned below). Such an image
# is for no unit until the owner enters the RULES lines (proposed text:
# MAINLINE-LINUX-INT-2026-11-10.md R-F.3, BOTH-SLOT-PACKAGING-2026-11-10.md).
STEP2_INST_SHA256=20aa6bc5d2146faace461eec0b50f741c681b3c58827788b9b806d9444b00203
STEP2_INST_PATH=usr/libexec/uc-pxx-step2/uc-pxx-bootctl-inst
# uc-pxx-step2 of uc-pxx-installer (ci/build-step2.sh, built twice
# byte-identical): 65eeed56... (5374076 bytes) of uc-pxx-installer mainline-rc-10
# 5de60c4, the R23 release: its clone gate holds the three profiles of
# 0.2.0-rc10 (ref_a, ref_b, bundles of the stage-1 build of 8baacf1) and the pin
# of uc-pxx-provision 65cd9cf1...; its mainline gate lists no normal payload
# (the release record MAINLINE-RC10-RELEASE-2026-11-15.md). Earlier: 05d2d48b... of
# 514d3c8 (the first RC-10 build, superseded by the marker fix), e6cf7147... of
# mainline-rc-9 811f1c2 (RC-9, gate 0.2.0-rc9 90dd4b74 and 0.2.0-rc9-eu 7cc16383). Earlier
# pins: 104e752f... of mainline-rc-8 1fcc625 (RC-8), dceb6953... of mainline-rc-8 15d3b2c (the fix-only build), f092d15e... of mainline-rc-7 0d8b5a8, 930a2d18... of mainline-rc-6 81a321f, fe4502b9... of mainline-rc-6, aace79f3... of mainline-rc-5,
# a44632a6... of d7e2113,
# ca1c1e67... of mainline-rc-4 6ac0b2c, b857680f... of 22eaf31, 524e89ba... of mainline-rc-3 3c397a7, 7049463f... of d754663, 13ea2508... of 6aab316, 3c2ba06f... of mainline-rc-2 d105ba2, b8c2a6d9... of c0d8f0b, 1cbb32ae... of mainline-rc be239e3,
# f7cc1d33... of 1605579, a4e753cc... of 9627b27 and b7710fa3... of mainline-step2-rest b9b2e98); NOT yet reviewed for the safety rules: a new build needs a new pin here
# mainline-rc-10b (the release of the health-based gate): 86d305ec... (5374076 bytes) of
# uc-pxx-installer mainline-rc-10b 3f06cc2 (ci/build-step2.sh; its clone gate holds the three
# profiles of the RC-10b stage-1 refs (uc-pxx-linux cf6393d) and the pin of uc-pxx-provision
# 6dfc8268...; no content compare of B or A). It replaces 65eeed56... of RC-10 above.
STEP2_BIN_SHA256=86d305ecfdcb9c6c027d1420e49b6f4ba0b77079e209807a2eeb121e4f4fa2cc
STEP2_BIN_PATH=usr/libexec/uc-pxx-step2/uc-pxx-step2
STEP2_DATA_SHA256=9162c65df08ac5577e38a2fe124d8cb1434b9b2bcfe787d6fba76055b8006791
STEP2_DATA_PATH=usr/sbin/uc-pxx-data-migrate
if [ -n "${UC_PXX_STEP2_BOOTCTL_INST:-}" ]; then
	sum=$(sha256sum "$UC_PXX_STEP2_BOOTCTL_INST" | cut -d' ' -f1)
	[ "$sum" = "$STEP2_INST_SHA256" ] || { echo "ERROR: UC_PXX_STEP2_BOOTCTL_INST has sha256 $sum, the reviewed r2 binary is $STEP2_INST_SHA256"; exit 1; }
	[ -n "${UC_PXX_STEP2_BIN:-}" ] && [ -f "$UC_PXX_STEP2_BIN" ] || { echo "ERROR: a STEP-2 build (UC_PXX_STEP2_BOOTCTL_INST) needs UC_PXX_STEP2_BIN (uc-pxx-step2)"; exit 1; }
	sum=$(sha256sum "$UC_PXX_STEP2_BIN" | cut -d' ' -f1)
	[ "$sum" = "$STEP2_BIN_SHA256" ] || { echo "ERROR: UC_PXX_STEP2_BIN has sha256 $sum, the pinned uc-pxx-step2 is $STEP2_BIN_SHA256"; exit 1; }
	[ -f "$R/$STEP2_DATA_PATH" ] && [ "$(sha256sum "$R/$STEP2_DATA_PATH" | cut -d' ' -f1)" = "$STEP2_DATA_SHA256" ] ||
		{ echo "ERROR: a STEP-2 build needs /$STEP2_DATA_PATH $STEP2_DATA_SHA256 (uc-pxx-board 0.2.0)"; exit 1; }
	install -d -m 700 -o 0 -g 0 $R/usr/libexec/uc-pxx-step2
	install -m 700 -o 0 -g 0 "$UC_PXX_STEP2_BOOTCTL_INST" "$R/$STEP2_INST_PATH"
	install -m 700 -o 0 -g 0 "$UC_PXX_STEP2_BIN" "$R/$STEP2_BIN_PATH"
	[ "$(sha256sum "$R/$STEP2_INST_PATH" | cut -d' ' -f1)" = "$STEP2_INST_SHA256" ] || { echo "ERROR: uc-pxx-bootctl-inst changed in the copy"; exit 1; }
	[ "$(sha256sum "$R/$STEP2_BIN_PATH" | cut -d' ' -f1)" = "$STEP2_BIN_SHA256" ] || { echo "ERROR: uc-pxx-step2 changed in the copy"; exit 1; }
	install -D -m 755 -o 0 -g 0 "$HERE/step2/init.d/uc-pxx-step2" $R/etc/init.d/uc-pxx-step2
	# an R23 base (UC_PXX_PROVISION_BIN, below) copies itself into the other
	# slot: the clone conf (UC_PXX_STEP2_KIND=clone, no payload folder)
	if [ -n "${UC_PXX_PROVISION_BIN:-}" ]; then
		install -D -m 644 -o 0 -g 0 "$HERE/step2/conf.d/uc-pxx-step2-clone" $R/etc/conf.d/uc-pxx-step2
	else
		install -D -m 644 -o 0 -g 0 "$HERE/step2/conf.d/uc-pxx-step2" $R/etc/conf.d/uc-pxx-step2
	fi
	mkdir -p $R/etc/runlevels/default
	ln -sf /etc/init.d/uc-pxx-step2 $R/etc/runlevels/default/uc-pxx-step2
	if [ "${UC_PXX_SSH_ACCESS:-}" = setup ]; then
		STEP2_KIND="end user"
		[ ! -e $R/etc/uc-pxx-step2 ] || { echo "ERROR: an end-user STEP-2 build has /etc/uc-pxx-step2"; exit 1; }
	else
		STEP2_KIND=supervised
		install -d -m 755 -o 0 -g 0 $R/etc/uc-pxx-step2
		echo "supervised: a person runs each step of step 2 with a rule-9 GO (STEP-2 BUILD default)" > $R/etc/uc-pxx-step2/supervised
	fi
	mkdir -p $R/etc/tsx
	# each sha256 is a word of its own (uc-pxx-installer internal/step2 markerNames:
	# the clone plan needs the running program's sha256 as a whitespace-separated
	# word; RC-10 release review BLOCKER-1: "SHA)," is no such word)
	echo "STEP-2 BUILD: /$STEP2_INST_PATH (uc-pxx-bootctl-inst r2 $STEP2_INST_SHA256 ), /$STEP2_BIN_PATH (uc-pxx-step2 $STEP2_BIN_SHA256 ), the service uc-pxx-step2 ($STEP2_KIND). For no unit before its RULES line." > $R/etc/tsx/step2-bootctl-inst
	log "STEP-2 BUILD (UC_PXX_STEP2_BOOTCTL_INST): r2 and uc-pxx-step2 in /usr/libexec/uc-pxx-step2, the service uc-pxx-step2 ($STEP2_KIND). For no unit before its RULES line"
else
	[ -z "${UC_PXX_STEP2_BIN:-}" ] || { echo "ERROR: UC_PXX_STEP2_BIN needs UC_PXX_STEP2_BOOTCTL_INST (a STEP-2 build)"; exit 1; }
fi
inst=$(cd $R && find . -name 'uc-pxx-bootctl-inst*' | sed 's#^\./##' | sort | tr '\n' ' ')
s2=$(cd $R && find . -name 'uc-pxx-step2*' | sed 's#^\./##' | sort | tr '\n' ' ')
# a copy of r2 or uc-pxx-step2 under another name, by its bytes (review r2):
# only files of their sizes are hashed (the sizes of the given binaries)
[ -z "${UC_PXX_STEP2_BIN:-}" ] || [ ! -f "$UC_PXX_STEP2_BIN" ] || STEP2_BIN_SIZE=${STEP2_BIN_SIZE:-$(stat -c %s "$UC_PXX_STEP2_BIN")}
cp2=$(cd $R && find . -type f \( -size ${STEP2_INST_SIZE:-777976}c -o -size ${STEP2_BIN_SIZE:-5374076}c \) -exec sha256sum {} + |
	awk -v a="$STEP2_INST_SHA256" -v b="$STEP2_BIN_SHA256" -v pa="./$STEP2_INST_PATH" -v pb="./$STEP2_BIN_PATH" \
		'($1 == a && $2 != pa) || ($1 == b && $2 != pb) { print $2 }' | tr '\n' ' ')
[ -z "$cp2" ] || { echo "ERROR: copies of uc-pxx-bootctl-inst or uc-pxx-step2 in the image: $cp2"; exit 1; }
if [ -n "${UC_PXX_STEP2_BOOTCTL_INST:-}" ]; then
	[ "$inst" = "$STEP2_INST_PATH " ] || { echo "ERROR: uc-pxx-bootctl-inst files in the image: '$inst' (only /$STEP2_INST_PATH is allowed)"; exit 1; }
	if [ "$STEP2_KIND" = supervised ]; then
		[ "$s2" = "etc/conf.d/uc-pxx-step2 etc/init.d/uc-pxx-step2 etc/runlevels/default/uc-pxx-step2 etc/uc-pxx-step2 usr/libexec/uc-pxx-step2 $STEP2_BIN_PATH " ] ||
			{ echo "ERROR: uc-pxx-step2 files in the image: '$s2'"; exit 1; }
		# the two folders hold exactly their files (review r2: the program reads files there)
		[ "$(cd $R && find etc/uc-pxx-step2 usr/libexec/uc-pxx-step2 | sort | tr '\n' ' ')" = "etc/uc-pxx-step2 etc/uc-pxx-step2/supervised usr/libexec/uc-pxx-step2 $STEP2_INST_PATH $STEP2_BIN_PATH " ] ||
			{ echo "ERROR: other files in /etc/uc-pxx-step2 or /usr/libexec/uc-pxx-step2"; exit 1; }
	else
		# the end-user STEP-2 build: no /etc/uc-pxx-step2 (no supervised marker)
		[ "$s2" = "etc/conf.d/uc-pxx-step2 etc/init.d/uc-pxx-step2 etc/runlevels/default/uc-pxx-step2 usr/libexec/uc-pxx-step2 $STEP2_BIN_PATH " ] ||
			{ echo "ERROR: uc-pxx-step2 files in the end-user image: '$s2'"; exit 1; }
		[ "$(cd $R && find usr/libexec/uc-pxx-step2 | sort | tr '\n' ' ')" = "usr/libexec/uc-pxx-step2 $STEP2_INST_PATH $STEP2_BIN_PATH " ] &&
			[ ! -e $R/etc/uc-pxx-step2 ] && [ ! -e $R/root/.ssh ] ||
			{ echo "ERROR: the end-user STEP-2 image: other files in /usr/libexec/uc-pxx-step2, or /etc/uc-pxx-step2 or /root/.ssh present"; exit 1; }
	fi
else
	[ -z "$inst" ] || { echo "ERROR: the image has uc-pxx-bootctl-inst ($inst): RULES.md allows it in no slot (a step-2 build needs UC_PXX_STEP2_BOOTCTL_INST)"; exit 1; }
	[ ! -e $R/usr/libexec/uc-pxx-step2 ] || { echo "ERROR: the image has /usr/libexec/uc-pxx-step2 without UC_PXX_STEP2_BOOTCTL_INST"; exit 1; }
	[ -z "$s2" ] || { echo "ERROR: the image has files of step 2 ($s2) without UC_PXX_STEP2_BOOTCTL_INST"; exit 1; }
fi

# The provisioning set of an R23 BASE build (DESIGN-R23 §3, §7.2;
# UC_PXX_PROVISION_BIN, off by default). The base is the console profile with
# the step-2 set and the USB set; its first boot installs the chosen profile
# (Kiosk + Home Assistant, Kiosk only, or nothing for Console only) from one
# pinned bundle (uc-pxx-provision of uc-pxx-installer, its sha256 an input:
# UC_PXX_PROVISION_SHA256). The set:
#   /usr/libexec/uc-pxx-provision/uc-pxx-provision (root, 0700, the folder 0700),
#   the OpenRC service uc-pxx-provision (rootfs/provision/, default runlevel)
#     and its conf file,
#   /usr/share/uc-pxx-provision/: profile-apply.sh, profile.sh, profiles/ and
#     overlay/ (profile-apply.sh --install-set: the profile steps that the unit
#     runs), and profiles.json (the pinned bundles and reference manifests,
#     written by rootfs/r23-refs.sh below).
# Step 2's difference (tools/mainline-payload/r23/clone-delta.json) removes the
# whole set from slot A. Without UC_PXX_PROVISION_BIN the image has no file of
# these names. Such an image is for no unit before its RULES lines.
PROV_BIN_PATH=usr/libexec/uc-pxx-provision/uc-pxx-provision
PROV_FILES="etc/conf.d/uc-pxx-provision etc/init.d/uc-pxx-provision etc/runlevels/default/uc-pxx-provision usr/libexec/uc-pxx-provision $PROV_BIN_PATH usr/share/uc-pxx-provision "
# The reviewed pin of uc-pxx-provision (R23-BASE-REVIEW MINOR-3): 65cd9cf1...
# (6946940 bytes) of uc-pxx-installer mainline-rc-10 370343f (ci/build-provision.sh,
# twice byte-identical; it holds the clone gate's profiles of 0.2.0-rc10). The
# input UC_PXX_PROVISION_SHA256 must be it. A new build needs a new pin here.
# mainline-rc-10b: 6dfc8268... (6946940 bytes) of uc-pxx-installer mainline-rc-10b baed193
# (ci/build-provision.sh; the health gate in place of the content check against ref_b; the gate
# profiles of the RC-10b stage-1 refs). It replaces 65cd9cf1... of RC-10 above.
PROV_PIN_SHA256=6dfc8268754e805066e92c77392540fda1721eb60521e90c03cc7fff14f54abb
PROV_SHA256=
if [ -n "${UC_PXX_PROVISION_BIN:-}" ]; then
	PROV_SHA256=${UC_PXX_PROVISION_SHA256:-}
	[ "$PROV_SHA256" = "$PROV_PIN_SHA256" ] || { echo "ERROR: UC_PXX_PROVISION_SHA256 '$PROV_SHA256' is not the pinned uc-pxx-provision $PROV_PIN_SHA256"; exit 1; }
	case $PROV_SHA256 in *[!0-9a-f]*|'') echo "ERROR: UC_PXX_PROVISION_BIN needs UC_PXX_PROVISION_SHA256 (64 lower-case hex digits)"; exit 1;; esac
	[ ${#PROV_SHA256} = 64 ] || { echo "ERROR: UC_PXX_PROVISION_SHA256 is not 64 hex digits"; exit 1; }
	sum=$(sha256sum "$UC_PXX_PROVISION_BIN" | cut -d' ' -f1)
	[ "$sum" = "$PROV_SHA256" ] || { echo "ERROR: UC_PXX_PROVISION_BIN has sha256 $sum, the input pin is $PROV_SHA256"; exit 1; }
	[ "$PROFILE" = console ] || { echo "ERROR: an R23 base (UC_PXX_PROVISION_BIN) is the console profile, not $PROFILE"; exit 1; }
	[ "$DEV" != 1 ] || { echo "ERROR: an R23 base is built from the packages (not UC_PXX_DEV_OVERLAY)"; exit 1; }
	[ -n "${UC_PXX_STEP2_BOOTCTL_INST:-}" ] && [ -n "${UC_PXX_XFER_BIN:-}" ] ||
		{ echo "ERROR: an R23 base is a STEP-2 build with the USB set (UC_PXX_STEP2_BOOTCTL_INST, UC_PXX_XFER_BIN)"; exit 1; }
	[ -n "${UC_PXX_R23_RELEASE:-}" ] && [ -n "${UC_PXX_PROVISION_URLS:-}" ] ||
		{ echo "ERROR: an R23 base needs UC_PXX_R23_RELEASE and UC_PXX_PROVISION_URLS"; exit 1; }
	install -d -m 700 -o 0 -g 0 $R/usr/libexec/uc-pxx-provision
	install -m 700 -o 0 -g 0 "$UC_PXX_PROVISION_BIN" "$R/$PROV_BIN_PATH"
	[ "$(sha256sum "$R/$PROV_BIN_PATH" | cut -d' ' -f1)" = "$PROV_SHA256" ] || { echo "ERROR: uc-pxx-provision changed in the copy"; exit 1; }
	install -D -m 755 -o 0 -g 0 "$HERE/provision/init.d/uc-pxx-provision" $R/etc/init.d/uc-pxx-provision
	install -D -m 644 -o 0 -g 0 "$HERE/provision/conf.d/uc-pxx-provision" $R/etc/conf.d/uc-pxx-provision
	ln -sf /etc/init.d/uc-pxx-provision $R/etc/runlevels/default/uc-pxx-provision
	sh "$HERE/profile-apply.sh" --install-set $R/usr/share/uc-pxx-provision
	# what uc-pxx-provision needs of the base (R23-FORMATS §12 item 4): rc-service
	# (it takes the gadget from uc-pxx-usb), the receiver's user and group 990
	# (the USB set), Go's CA bundle for the https fetch, setsid (its init
	# script), and the step-2 clone conf
	[ -x $R/sbin/rc-service ] && [ -f $R/etc/ssl/certs/ca-certificates.crt ] && [ -x $R/usr/bin/setsid ] ||
		{ echo "ERROR: an R23 base needs /sbin/rc-service, /etc/ssl/certs/ca-certificates.crt and /usr/bin/setsid"; exit 1; }
	grep -qx 'uc-pxx-xfer:x:990:990:[^:]*:[^:]*:/sbin/nologin' $R/etc/passwd && grep -qx 'uc-pxx-xfer:x:990:' $R/etc/group ||
		{ echo "ERROR: an R23 base needs the user and group uc-pxx-xfer (990)"; exit 1; }
	cmp -s "$HERE/step2/conf.d/uc-pxx-step2-clone" $R/etc/conf.d/uc-pxx-step2 ||
		{ echo "ERROR: an R23 base needs the step-2 clone conf (UC_PXX_STEP2_KIND=clone)"; exit 1; }
	log "the provisioning set: uc-pxx-provision $PROV_SHA256, the service uc-pxx-provision, /usr/share/uc-pxx-provision"
fi
prov=$(cd $R && find . -name 'uc-pxx-provision*' | sed 's#^\./##' | sort | tr '\n' ' ')
if [ -n "${UC_PXX_PROVISION_BIN:-}" ]; then
	[ "$prov" = "$PROV_FILES" ] || { echo "ERROR: the provisioning set in the image is '$prov', not exactly '$PROV_FILES'"; exit 1; }
	[ "$(cd $R && find usr/libexec/uc-pxx-provision | sort | tr '\n' ' ')" = "usr/libexec/uc-pxx-provision $PROV_BIN_PATH " ] ||
		{ echo "ERROR: other files in /usr/libexec/uc-pxx-provision"; exit 1; }
	# no copy of the binary under another name
	psize=$(stat -c %s "$R/$PROV_BIN_PATH")
	cpp=$(cd $R && find . -type f -size "${psize}c" -exec sha256sum {} + | awk -v a="$PROV_SHA256" -v pa="./$PROV_BIN_PATH" '$1 == a && $2 != pa { print $2 }' | tr '\n' ' ')
	[ -z "$cpp" ] || { echo "ERROR: copies of uc-pxx-provision in the image: $cpp"; exit 1; }
else
	[ -z "$prov" ] || { echo "ERROR: the image has files of the provisioning set ($prov) without UC_PXX_PROVISION_BIN"; exit 1; }
fi

log "manifest and sizes"
mkdir -p "$OUT"
apk info --root $R -v 2>/dev/null | sort > "$OUT/rootfs.manifest"
{
	echo "rootfs total: $(du -sm $R | cut -f1) MiB, $(wc -l < "$OUT/rootfs.manifest") packages"
	echo "largest packages (installed size):"
	apk info --root $R -s $(apk info --root $R 2>/dev/null) 2>/dev/null | awk '
		/ installed size:$/ {p=$1; sub(/-[0-9].*$/, "", p); next}
		NF==2 && p != "" {v=$1; u=$2; if (u=="KiB") v/=1024; if (u=="GiB") v*=1024; if (u=="B") v/=1048576; printf "%8.1f MiB  %s\n", v, p; p=""}' | sort -rn | head -25
	# the apparent sizes (du -b): the blocks that the build host's file system
	# gives a folder's files vary by a fraction of a MiB between two builds
	# (RC-10 release: 21 and 22 MiB for /usr/libexec), the file sizes do not
	echo "largest directories (apparent size):"
	du -b -xm -d 3 $R/usr $R/lib $R/opt 2>/dev/null | sort -k1,1rn -k2 | head -15 | sed "s|$R||"
	echo "profile: $PROFILE"
	if [ "$DEV" = 1 ]; then echo "image source: TEST BUILD (UC_PXX_DEV_OVERLAY=1), common packages and the repository files"
	else echo "image source: packages (uc-pxx-$PROFILE)"; fi
	[ -z "$DEVKEY" ] || echo "image source: TEST BUILD, the uc-pxx packages signed by $DEVKEY (sha256 $DEVKEY_SHA), not published"
	echo "root password: $ROOT_PW_RESULT"
	echo "packages (apk add): $PKGS"
	echo "tsx-aports: panel repository URL $TSX_APK_URL/$ALPINE/{common,uc-pxx}"
	ls $R/lib/modules 2>/dev/null | sed 's/^/kernel modules: /'
} > "$OUT/rootfs.sizes"
cat "$OUT/rootfs.sizes"

# the apk info calls above fill $R/var/cache/apk again, so clear it again
rm -rf $R/var/cache/apk/*

# The shared library check above runs tsx-idled in the chroot, and a build
# step can leave its log. A panel makes a new log at its first start, so the
# image ships with none.
rm -f $R/var/log/tsx-idled.log

# The R23 references (rootfs/r23-refs.sh, DESIGN-R23 §4.6, §7.2): from this
# base, for each profile, the reference B (the bundle installed by the base's
# own apk, the profile steps by the base's own profile-apply.sh) and the
# reference A (B with step 2's difference), their content manifests, the
# profile bundles, then profiles.json into the base.
if [ -n "${UC_PXX_PROVISION_BIN:-}" ]; then
	. "$HERE/r23-refs.sh"
	r23_refs
	[ -f $R/usr/share/uc-pxx-provision/profiles.json ] || { echo "ERROR: no profiles.json"; exit 1; }
	# the folder holds exactly the set and profiles.json
	sh "$HERE/profile-apply.sh" --install-set /build/set-check
	want=$(cd /build/set-check && { find . ; echo ./profiles.json; } | sort | tr '\n' ' ')
	got=$(cd $R/usr/share/uc-pxx-provision && find . | sort | tr '\n' ' ')
	[ "$want" = "$got" ] || { echo "ERROR: /usr/share/uc-pxx-provision is '$got', not '$want'"; exit 1; }
	rm -rf /build/set-check
fi

if [ -n "$SDE" ]; then
	log "reproducible tree (SOURCE_DATE_EPOCH $SDE)"
	# busybox adduser and passwd write today as the day of the last password
	# change. Use the day of SOURCE_DATE_EPOCH. An empty day and the day 0
	# (change at the next login) stay.
	for f in $R/etc/shadow $R/etc/shadow-; do
		[ -f "$f" ] || continue
		awk -F: -v OFS=: -v d=$((SDE / 86400)) 'NF >= 3 && $3 ~ /^[0-9]+$/ && $3 > 0 { $3 = d } { print }' "$f" > /build/shadow.new
		cat /build/shadow.new > "$f"; rm -f /build/shadow.new
	done
	# apk writes the time of each run into /var/log/apk.log ("Running `apk
	# add ...` at TIME"). Use SOURCE_DATE_EPOCH.
	L=$R/var/log/apk.log
	if [ -f $L ]; then
		STAMP=$(date -u -d "@$SDE" '+%Y-%m-%d %H:%M:%S')
		sed -i "s/^\(Running \`apk .*\` at \)[0-9-]* [0-9:]*\$/\1$STAMP/" $L
		! grep '^Running `apk ' $L | grep -v -F "\` at $STAMP" | grep -q . ||
			{ echo "ERROR: $L has a run with another time"; grep '^Running' $L; exit 1; }
	fi
	# (the debug info of the lva libraries: rootfs/lva-build.sh)
	# No file time after SOURCE_DATE_EPOCH (the files that the build made or
	# changed; the times of the packages are older and stay).
	touch -d "@$SDE" /build/sde.ref
	find $R -newer /build/sde.ref -exec touch -h -d "@$SDE" {} +
	# The fontconfig caches of the package triggers hold the times of the font
	# folders at the install. Make them again for the times of the image.
	if [ -x $R/usr/bin/fc-cache ]; then
		rm -f $R/var/cache/fontconfig/*
		chroot $R /usr/bin/fc-cache -s -f >/dev/null || { echo "ERROR: fc-cache failed"; exit 1; }
		find $R -newer /build/sde.ref -exec touch -h -d "@$SDE" {} +
	fi
	rm -f /build/sde.ref
fi
# An R23 base: the image is the tree that the references were made from (the
# console reference B: the same manifest after the steps above)
if [ -n "${UC_PXX_PROVISION_BIN:-}" ]; then
	got=$(python3 -I "$TOP/tools/mainline-payload/contentmanifest.py" build $R --exclude "$TOP/tools/mainline-payload/r23/content-exclude.txt" | cut -d' ' -f1)
	want=$(sed -n 's/^REF_B_CONSOLE=//p' "$OUT/r23/refs.txt")
	[ -n "$got" ] && [ "$got" = "$want" ] || { echo "ERROR: the base's content manifest is $got, not REF_B_CONSOLE $want"; exit 1; }
	log "the base is the console reference B ($got)"
fi
# the state folder of the tsx tools (above): root, 0755, a folder, empty
[ -d $R/var/lib/tsx ] && [ ! -L $R/var/lib/tsx ] && [ "$(stat -c '%u:%g %a' $R/var/lib/tsx)" = "0:0 755" ] &&
	[ -z "$(ls -A $R/var/lib/tsx)" ] || { echo "ERROR: /var/lib/tsx is not an empty folder root:root 0755 in the image"; exit 1; }
log "tarball"
tar -C $R --sort=name --numeric-owner -cpf - . | gzip -6 -n > "$OUT/rootfs.tar.gz"
# The ext4 image is compact (the content plus headroom). The initramfs grows
# the file system to fill system_a (1792 MiB) on the first boot. So the image
# must leave room for that to be worth anything.
used=$(du -sm $R | cut -f1)
IMG_MB=${IMG_MB:-$(( (used * 105 / 100) + ${IMG_HEADROOM_MB:-256} ))}
[ "$IMG_MB" -le 1700 ] || { echo "rootfs.ext4 would be $IMG_MB MiB: too large for system_a (1792 MiB)"; exit 1; }
log "ext4 image (${IMG_MB} MiB, label tsxroot; content ${used} MiB)"
rm -f "$OUT/rootfs.ext4"
# ROOTFS_UUID fixes the UUID, the metadata checksum seed and the directory hash
# seed. mke2fs takes its times from SOURCE_DATE_EPOCH when it is set. Always
# 4 KiB blocks and the "default" usage type (DESIGN-R23 §1: for a small image,
# such as the R23 base, mke2fs would pick 1 KiB blocks and the "small" type;
# the unit grows the file system to fill the slot).
UUIDARGS=
[ -z "${ROOTFS_UUID:-}" ] || UUIDARGS="-U $ROOTFS_UUID -E hash_seed=$ROOTFS_UUID"
# shellcheck disable=SC2086 # empty or four words
mke2fs -q -t ext4 -b 4096 -T default -L tsxroot -m 1 $UUIDARGS -d $R "$OUT/rootfs.ext4" "${IMG_MB}M"
e2fsck -fn "$OUT/rootfs.ext4" >/dev/null && echo "e2fsck clean"
# The R23 base ships compressed (manifest schema 3, rootfs_zst): zstd -19 with
# a window of at most 8 MiB (the unit's decoder), one thread (the same bytes)
ZST=
if [ -n "${UC_PXX_PROVISION_BIN:-}" ]; then
	rm -f "$OUT/rootfs.ext4.zst"
	zstd -q -19 --zstd=wlog=23 -T1 --no-progress -o "$OUT/rootfs.ext4.zst" "$OUT/rootfs.ext4"
	zstd -q -d -c "$OUT/rootfs.ext4.zst" | cmp -s - "$OUT/rootfs.ext4" || { echo "ERROR: rootfs.ext4.zst does not unpack to rootfs.ext4"; exit 1; }
	ZST=rootfs.ext4.zst
fi
# shellcheck disable=SC2086 # empty or one word
(cd "$OUT" && sha256sum rootfs.tar.gz rootfs.ext4 $ZST > rootfs.sha256)
chown "$UIDGID" "$OUT"/rootfs.*
[ ! -d "$OUT/r23" ] || chown -R "$UIDGID" "$OUT/r23"
ls -ls "$OUT"/rootfs.*
