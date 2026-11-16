#!/bin/sh
# profile-apply.sh: the profile steps of an image (DESIGN-R23 §3.5). One script
# for the build and for the unit: mkrootfs.sh runs it on the image it builds,
# the R23 reference builds (rootfs/r23-refs.sh) and uc-pxx-provision on the
# unit run the copy in /usr/share/uc-pxx-provision of the base image.
#
#   profile-apply.sh PROFILE ROOT [--lva FILE]
#       Apply the profile console, kiosk or ha (profiles/*.list, profile.sh)
#       to the tree at ROOT, after the packages of the profile are installed.
#       ROOT / is the running system (the unit). Another ROOT is an image
#       tree: the script copies itself into ROOT/tmp and runs there under
#       chroot, so the tools of the tree (its busybox) do the work, as on the
#       unit. --lva FILE: the packed /opt/lva of the ha profile (lva.tar of its
#       bundle; rootfs/lva-build.sh makes it). The ha profile needs it, the
#       others refuse it.
#   profile-apply.sh --install-set DEST
#       Copy the set that the script needs (itself, profile.sh, profiles/ and
#       the files of profiles/image.list in overlay/) to DEST: the folder
#       /usr/share/uc-pxx-provision of a base image (root, folders 0755,
#       scripts 0755, data 0644).
#
# The steps, in this order (a cut leaves the services of the profile off, so
# a half kiosk never starts; the next run does every step again):
#   1. lva (ha): /opt/lva from --lva (the old /opt/lva is removed)
#   2. owner root for every entry of /etc and /usr/local (no link followed)
#   3. the shared library check of the profile's programs
#   4. the users and groups of the profile (kiosk, tsx-setup)
#   5. the hostname, only when /etc/hostname holds a default (none, localhost,
#      tsx-console, tsx-kiosk): tsx-console for console, else tsx-kiosk
#   6. the trim: Chromium locales, man/doc/info, apk's cache, the locales,
#      the sway wallpapers, Python bytecode
#   7. the fontconfig caches (fc-cache -s -f)
#   8. with SOURCE_DATE_EPOCH: the shadow day of each entry, as mkrootfs.sh
#   9. the files of profiles/image.list (a file the profile does not have is
#      removed: the ha profile has no /etc/tsx/profile), each written new and
#      renamed into place
#  10. the services of the profile (links in /etc/runlevels; sshd is left as
#      it is in an end-user tree, where the setup plugin
#      /usr/local/lib/tsx/config.d/uc_pxx_ssh.sh turns it on)
#  11. sync
# It installs no package and writes no partition: only files of the tree.
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
PS=$HERE/profile.sh
PD=${TSX_PROFILE_DIR:-$HERE/profiles}
OV=${TSX_OVERLAY_DIR:-$HERE/overlay}
die() { echo "profile-apply.sh: $*" >&2; exit 1; }
log() { echo "profile-apply: $*"; }
umask 022

# image_files: the paths of profiles/image.list
image_files() { awk '/^[ \t]*(#|$)/ { next } $1 == "image" { print $2 }' "$PD/image.list"; }

# fixmode SRC DEST: 755 for a folder or a file with an execute bit, else 644
fixmode() { if [ -d "$1" ] || [ -x "$1" ]; then chmod 755 "$2"; else chmod 644 "$2"; fi; }

install_set() {
	D=$1
	[ ! -e "$D" ] || [ -d "$D" ] || die "--install-set: $D is not a folder"
	mkdir -p "$D"
	install -m 755 "$HERE/profile-apply.sh" "$D/profile-apply.sh"
	install -m 755 "$PS" "$D/profile.sh"
	install -d -m 755 "$D/profiles"
	for f in "$PD"/*.list; do install -m 644 "$f" "$D/profiles/${f##*/}"; done
	for p in console kiosk ha; do
		[ -d "$PD/$p/overlay" ] || continue
		for f in $(cd "$PD/$p/overlay" && find . -type f | sort); do
			f=${f#./}
			install -d -m 755 "$D/profiles/$p/overlay/$(dirname "$f")"
			cp -L "$PD/$p/overlay/$f" "$D/profiles/$p/overlay/$f"
			fixmode "$PD/$p/overlay/$f" "$D/profiles/$p/overlay/$f"
		done
	done
	for f in $(image_files); do
		[ -e "$OV/$f" ] || continue
		install -d -m 755 "$D/overlay/$(dirname "$f")"
		cp -L "$OV/$f" "$D/overlay/$f"
		fixmode "$OV/$f" "$D/overlay/$f"
	done
	# folders 0755 (install -d does not change a folder that was there)
	find "$D" -type d -exec chmod 755 {} +
	if [ "$(id -u)" = 0 ]; then chown -R 0:0 "$D"; fi
}

if [ "${1:-}" = --install-set ]; then
	[ $# = 2 ] || die "usage: profile-apply.sh --install-set DEST"
	install_set "$2"
	exit 0
fi
[ $# -ge 2 ] || die "usage: profile-apply.sh PROFILE ROOT [--lva FILE] | --install-set DEST"
P=$1 ROOT=$2; shift 2
LVA=
while [ $# -gt 0 ]; do
	case $1 in
	--lva) [ $# -ge 2 ] || die "--lva needs a file"; LVA=$2; shift 2;;
	*) die "unknown option $1";;
	esac
done
sh "$PS" includes "$P" >/dev/null || die "unknown profile '$P'"
has() { sh "$PS" has "$P" "$1" "$2"; }
if has step lva; then
	[ -n "$LVA" ] && [ -f "$LVA" ] || die "the $P profile needs --lva FILE (the packed /opt/lva)"
else
	[ -z "$LVA" ] || die "the $P profile takes no --lva"
fi
[ -d "$ROOT" ] || die "$ROOT is not a folder"

if [ "$ROOT" != / ]; then
	# An image tree: run there, with the tools of the tree.
	[ -x "$ROOT/bin/sh" ] || [ -L "$ROOT/bin/sh" ] || die "$ROOT has no /bin/sh"
	rel=/tmp/uc-pxx-profile-apply.$$
	S=$ROOT$rel
	rm -rf "$S"; mkdir -p "$S"
	install_set "$S/set"
	A=
	if [ -n "$LVA" ]; then cp "$LVA" "$S/lva.tar"; A="--lva $rel/lva.tar"; fi
	# shellcheck disable=SC2086 # empty or two words
	if chroot "$ROOT" /bin/sh "$rel/set/profile-apply.sh" "$P" / $A; then rc=0; else rc=$?; fi
	rm -rf "$S"
	exit $rc
fi

# ---- the running system (or the tree, under chroot) -------------------------
log "profile $P"

# 1. /opt/lva of the ha profile (DESIGN-R23 §3.5: the reproducible /opt/lva of
# the reference build; install-lva.sh needs a compiler and PyPI, the unit has
# neither). Every member must be lva or under lva/.
if [ -n "$LVA" ]; then
	bad=$(tar -tf "$LVA" | awk '
		{ n = $0; sub(/^\.\//, "", n) }
		n !~ /^lva(\/|$)/ || n ~ /(^|\/)\.\.(\/|$)/ { print; exit }') || die "cannot read $LVA"
	[ -z "$bad" ] || die "$LVA has a member outside lva/: $bad"
	rm -rf /opt/.lva-new
	mkdir -p /opt/.lva-new
	tar -xf "$LVA" -C /opt/.lva-new || die "cannot unpack $LVA"
	[ -d /opt/.lva-new/lva ] || die "$LVA has no folder lva"
	rm -rf /opt/lva
	mv /opt/.lva-new/lva /opt/lva
	rmdir /opt/.lva-new
	log "/opt/lva from $(basename "$LVA") ($(sha256sum "$LVA" | cut -d' ' -f1))"
fi

# 2. the owner of the files that the packages put into /etc and /usr/local
find /etc /usr/local \( ! -user 0 -o ! -group 0 \) -exec chown -h 0:0 {} +

# 3. every program of the profile must find its shared libraries
BINS="/usr/local/sbin/tsx-idled /usr/local/bin/tsx-splash"
if has svc kiosk; then BINS="$BINS /usr/local/bin/tsx-overlay"; fi
if [ -x /usr/bin/sendspin-cli ]; then BINS="$BINS /usr/bin/sendspin-cli"; fi
for bin in $BINS; do
	out=$(/lib/ld-musl-aarch64.so.1 --list "$bin" 2>&1) || true
	if printf '%s\n' "$out" | grep -qE 'Error (loading|relocating)|not found'; then
		printf '%s\n' "$out" | head -n 5
		die "$bin: missing shared libraries"
	fi
done

# 4. the users of the profile. The setup page has its OWN unprivileged user,
# not "kiosk" (docs/rootfs.md "Setup page").
USERS=$(sh "$PS" entries "$P" user | tr '\n' ' ')
added=
case " $USERS " in *" kiosk "*)
	addgroup -S seat 2>/dev/null || true
	addgroup -S render 2>/dev/null || true
	# The package tsx-kiosk makes this user in its pre-install script.
	getent passwd kiosk >/dev/null || { adduser -D -H -h /var/lib/kiosk -s /sbin/nologin -g "kiosk browser" kiosk; added="$added kiosk"; }
	for g in video input seat render audio; do addgroup kiosk $g 2>/dev/null || true; done
	mkdir -p /var/lib/kiosk && chown kiosk:kiosk /var/lib/kiosk;;
esac
case " $USERS " in *" tsx-setup "*)
	getent passwd tsx-setup >/dev/null || { adduser -D -H -s /sbin/nologin -g "on-panel setup page" tsx-setup; added="$added tsx-setup"; };;
esac
[ -z "$added" ] || log "users:$added"

# 5. the hostname of the profile, never over a name that a person set
case "$P" in console) H=tsx-console;; *) H=tsx-kiosk;; esac
cur=$(cat /etc/hostname 2>/dev/null || true)
case "$cur" in
''|localhost|tsx-console|tsx-kiosk)
	printf '%s\n' "$H" > /etc/hostname.profile-apply
	mv -f /etc/hostname.profile-apply /etc/hostname
	printf '127.0.0.1\tlocalhost %s\n::1\t\tlocalhost\n' "$H" > /etc/hosts.profile-apply
	mv -f /etc/hosts.profile-apply /etc/hosts;;
*) log "keeps the hostname $cur";;
esac

# 6. the trim
# Chromium UI locales: en-US only
if [ -d /usr/lib/chromium/locales ]; then
	find /usr/lib/chromium/locales -name '*.pak' ! -name 'en-US.pak' -exec rm -f {} +
fi
# man pages / doc / info: never read on a headless kiosk
rm -rf /usr/share/man /usr/share/doc /usr/share/info
# apk's own index cache
rm -rf /var/cache/apk/* /lib/apk/db/scripts.tar
if [ -d /usr/share/locale ]; then
	find /usr/share/locale -mindepth 1 -maxdepth 1 -type d ! -name 'en*' ! -name C -exec rm -rf {} +
fi
# sway-wallpapers: install_if-bound to sway, unused (the kiosk's background is
# the boot splash, usr/local/bin/kiosk-session)
rm -rf /usr/share/backgrounds/sway
# python bytecode caches: the -pyc subpackages are install_if-bound to
# python3; the interpreter recompiles at the first import
for d in /usr/lib/python3*; do
	[ -d "$d" ] || continue
	find "$d" -depth \( -type d -name '__pycache__' -o -type f -name '*.pyc' \) -exec rm -rf {} +
done

# 7. the fontconfig caches of the fonts of the profile
if [ -x /usr/bin/fc-cache ]; then
	fc-cache -s -f >/dev/null || die "fc-cache failed"
fi

# 8. a reproducible build: the shadow day is the day of SOURCE_DATE_EPOCH
# (mkrootfs.sh does the same for the whole image)
if [ -n "${SOURCE_DATE_EPOCH:-}" ]; then
	case $SOURCE_DATE_EPOCH in *[!0-9]*) die "SOURCE_DATE_EPOCH=$SOURCE_DATE_EPOCH is not a number";; esac
	for f in /etc/shadow /etc/shadow-; do
		[ -f "$f" ] || continue
		awk -F: -v OFS=: -v d=$((SOURCE_DATE_EPOCH / 86400)) 'NF >= 3 && $3 ~ /^[0-9]+$/ && $3 > 0 { $3 = d } { print }' "$f" > "$f.profile-apply"
		cat "$f.profile-apply" > "$f"; rm -f "$f.profile-apply"
	done
fi

# 9. the files of the image that depend on the profile (profiles/image.list):
# the profile's own copy wins over overlay/; none: the file is removed
for f in $(image_files); do
	if [ -e "$PD/$P/overlay/$f" ]; then src=$PD/$P/overlay/$f
	elif [ -e "$OV/$f" ]; then src=$OV/$f
	else
		if [ -e "/$f" ] || [ -L "/$f" ]; then rm -f "/$f"; log "removed /$f (the $P profile has none)"; fi
		continue
	fi
	if [ -f "/$f" ] && [ ! -L "/$f" ] && cmp -s "$src" "/$f"; then
		fixmode "$src" "/$f"; chown 0:0 "/$f"
		continue
	fi
	mkdir -p "/$(dirname "$f")"
	rm -f "/$f.profile-apply"
	cp -L "$src" "/$f.profile-apply"
	fixmode "$src" "/$f.profile-apply"; chown 0:0 "/$f.profile-apply"
	mv -f "/$f.profile-apply" "/$f"
	log "/$f"
done

# 10. the services of the profile, last
SVC_SYSINIT=$(sh "$PS" entries "$P" svc | awk '$1 == "sysinit" { print $2 }' | tr '\n' ' ')
SVC_BOOT=$(sh "$PS" entries "$P" svc | awk '$1 == "boot" { print $2 }' | tr '\n' ' ')
SVC_DEFAULT=$(sh "$PS" entries "$P" svc | awk '$1 == "default" { print $2 }' | tr '\n' ' ')
ENDUSER_SSH=no
if [ -e /usr/local/lib/tsx/config.d/uc_pxx_ssh.sh ]; then ENDUSER_SSH=yes; fi
svc() {
	lvl=$1; shift
	mkdir -p "/etc/runlevels/$lvl"
	for s in "$@"; do
		[ -e "/etc/init.d/$s" ] || die "MISSING $lvl service $s"
		if [ "$s" = sshd ] && [ "$ENDUSER_SSH" = yes ]; then continue; fi
		[ -L "/etc/runlevels/$lvl/$s" ] || ln -s "/etc/init.d/$s" "/etc/runlevels/$lvl/$s"
	done
}
# shellcheck disable=SC2086 # word lists
svc sysinit devfs dmesg udev udev-trigger udev-settle $SVC_SYSINIT
# shellcheck disable=SC2086
svc boot root localmount modules sysctl hostname bootmisc syslog hwclock seedrng udev-postmount machine-id $SVC_BOOT
# shellcheck disable=SC2086
svc default $SVC_DEFAULT
svc shutdown mount-ro killprocs savecache

# 11. on the disk
sync
log "done ($P)"
