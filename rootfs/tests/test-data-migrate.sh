#!/bin/sh
# Test of the data tools of step 2 (MAINLINE-STEP2-DESIGN §6, §7.3, L6, L8):
# uc-pxx-data-migrate (status, check, format, migrate), uc-pxx-data-release
# (copy, wipe) and the mount of the finished /data by uc-pxx-lvm, on real
# loop devices with real file systems. A sparse file of the real size of
# userdata (13724639 sectors) stands in for mmcblk0p28, a small one for the
# root file system; a made-up /sys/class/block names them.
# It must run as root with loop devices, mount and the e2fsprogs of the
# panel (mkfs.ext4, e2fsck), util-linux blkdiscard, busybox and python3: in a
# privileged container without network, for example on the build host:
#   docker run --rm --privileged --network none -v "$PWD:/w:ro" IMAGE \
#     sh /w/rootfs/tests/test-data-migrate.sh
# (IMAGE: Alpine 3.24 with e2fsprogs util-linux-misc python3). Without root
# or losetup it prints SKIPPED.
set -u
HERE=$(cd "$(dirname "$0")/.." && pwd)
MIG=$HERE/overlay/usr/sbin/uc-pxx-data-migrate
REL=$HERE/overlay/usr/sbin/uc-pxx-data-release
LVM=$HERE/overlay/etc/init.d/uc-pxx-lvm
[ "$(id -u)" = 0 ] || { echo "SKIPPED: not root (run it in a privileged container)"; exit 0; }
for t in losetup mkfs.ext4 e2fsck blkid python3 mount; do
	command -v $t > /dev/null || { echo "SKIPPED: no $t"; exit 0; }
done
T=$(mktemp -d)
LOOPS=
cleanup() {
	for m in $(awk -v t="$T" 'index($2, t) == 1 { print $2 }' /proc/mounts | sort -r); do umount "$m" 2>/dev/null || umount -l "$m"; done
	for l in $LOOPS; do losetup -d "$l" 2>/dev/null; done
	rm -rf "$T"
}
trap cleanup EXIT
N=0 F=0
ok()  { N=$((N + 1)); echo "  ok: $*"; }
bad() { F=$((F + 1)); echo "  FAIL: $*"; }
eq() { if [ "$1" = "$2" ]; then ok "$3"; else bad "$3 (got '$1', want '$2')"; fi; }

UD_SECT=13724639
truncate -s $((UD_SECT * 512)) "$T/userdata.img"
truncate -s 64M "$T/rootfs.img"
# attach FILE: a free loop device for FILE (busybox losetup has no --show)
attach() { _l=$(losetup -f) && losetup "$_l" "$1" && echo "$_l"; }
LU=$(attach "$T/userdata.img") || { echo "SKIPPED: losetup failed (no loop devices?)"; exit 0; }
LOOPS="$LU"
LR=$(attach "$T/rootfs.img") || { echo "FAIL: no second loop device"; exit 1; }
LOOPS="$LOOPS $LR"
mkfs.ext4 -q -F -L tsxroot "$LR"

# the made-up eMMC: sysfs, /dev links to the loops
S=$T/sys D=$T/dev
mkdir -p "$S/mmcblk0/device" "$D" "$T/run" "$T/bin"
echo MMC > "$S/mmcblk0/device/type"
p() { mkdir -p "$S/$1/holders"; echo "PARTNAME=$2" > "$S/$1/uevent"; echo "$3" > "$S/$1/start"; echo "$4" > "$S/$1/size"; echo "$5" > "$S/$1/dev"; }
p mmcblk0p22 system_a 3703808 3670016 179:22
p mmcblk0p23 system_b 7373824 3670016 179:23
p mmcblk0p28 userdata 16811008 $UD_SECT 179:28
ln -s "$LU" "$D/mmcblk0p28"; ln -s "$LR" "$D/mmcblk0p22"; ln -s "$LR" "$D/mmcblk0p23"
# the booted slot and the root of the running system
printf '#!/bin/sh\n[ -e "%s/slotrc" ] && exit "$(cat "%s/slotrc")"\ncat "%s/slot"\n' "$T" "$T" "$T" > "$T/bin/uc-pxx-slot"
# rc-service: the services in $T/started are running; it logs stop and start
cat > "$T/bin/rc-service" <<EOF
#!/bin/sh
[ "\$1" = -q ] && shift
if [ "\$1" = -e ]; then grep -qx "\$2" "$T/installed"; exit; fi
echo "\$2 \$1" >> "$T/rc.log"
case \$2 in
status) grep -qx "\$1" "$T/started";;
stop) grep -vx "\$1" "$T/started" > "$T/started.n"; mv "$T/started.n" "$T/started";;
start) echo "\$1" >> "$T/started";;
esac
EOF
# uc-pxx-bootctl status: the A/B state in $T/ab ("A B": prio,tries,succ each)
cat > "$T/bin/bootctl" <<EOF
#!/bin/sh
set -- \$(tr ', ' '  ' < "$T/ab")
echo "uc-pxx-bootctl: current: A{prio \$1 tries \$2 succ \$3} B{prio \$4 tries \$5 succ \$6} crc 1" >&2
EOF
# the phase-1 volume group (release refuses it): exit 0 when $T/vg exists
printf '#!/bin/sh\n[ -e "%s/vg" ]\n' "$T" > "$T/bin/lvm"
chmod 755 "$T/bin"/*
printf 'kiosk\ntsx-voice\nsyslog\n' > "$T/installed"
ab() { echo "$1 $2" > "$T/ab"; }
ab 15,0,1 0,0,0
printf '# no label lines\ntmpfs /tmp tmpfs nosuid 0 0\n' > "$T/fstab"
slot() { echo "$1" > "$T/slot"; rm -f "$T/slotrc"; printf '22 1 179:%s / / rw - ext4 /dev/root rw\n' "$2" > "$T/mountinfo"; }
slot a 22

# the running system: a tree with /data (panel.conf) and the tsx-data folders
mksrc() {
	rm -rf "$T/src"; mkdir -p "$T/src"; R=$T/src
	mkdir -p "$R/data/tsx" "$R/var/lib/kiosk/profile" "$R/var/log" "$R/var/lib/tsx" "$R/root/.ssh" "$R/home/u" "$R/lib/firmware/brcm" "$R/etc"
	echo "UPDATE_MODE=manual" > "$R/data/tsx/panel.conf"
	echo "profile" > "$R/var/lib/kiosk/profile/Prefs"; ln -s Prefs "$R/var/lib/kiosk/profile/link"
	echo "log line" > "$R/var/log/messages"; echo "state" > "$R/var/lib/tsx/state"
	echo "ssh-ed25519 AAAA k@x" > "$R/root/.ssh/authorized_keys"; chmod 700 "$R/root/.ssh"; chmod 600 "$R/root/.ssh/authorized_keys"
	echo "home" > "$R/home/u/f"; chown 1000:1000 "$R/home/u" "$R/home/u/f"
	chmod 750 "$R/var/lib/kiosk"; chown 100:101 "$R/var/lib/kiosk"
	echo wifi > "$R/lib/firmware/brcm/brcmfmac43456-sdio.bin"; echo nvram > "$R/lib/firmware/brcm/brcmfmac43456-sdio.txt"
	echo bt > "$R/lib/firmware/brcm/BCM4345C5.hcd"
}
mksrc
printf 'kiosk\nsyslog\n' > "$T/started"
export TSX_BOOTCTL=$T/bin/bootctl UC_PXX_LVM=$T/bin/lvm TSX_SYSBLOCK=$S TSX_DEVDIR=$D UC_PXX_MOUNTINFO=$T/mountinfo UC_PXX_SLOT=$T/bin/uc-pxx-slot UC_PXX_SRC=$T/src \
	UC_PXX_FSTAB=$T/fstab UC_PXX_RUN=$T/run UC_PXX_RC_SERVICE=$T/bin/rc-service UC_PXX_MIGRATE_SERVICES="kiosk tsx-voice tsx-notinstalled syslog"
mig() { sh "$MIG" "$@" > "$T/out" 2> "$T/err"; echo $?; }
rel() { sh "$REL" "$@" > "$T/out" 2> "$T/err"; echo $?; }
ud_sha() { head -c 1048576 "$LU" | sha256sum | cut -d' ' -f1; }
tdig() { ( cd "$1" && find . \( -type f -o -type l \) | sort | while read -r f; do if [ -L "$f" ]; then echo "l $(readlink "$f") $f"; else echo "f $(sha256sum < "$f" | cut -c1-16) $(stat -c '%u:%g %a' "$f") $f"; fi; done ) | sha256sum | cut -c1-16; }
lab() { blkid "$LU" | sed -n 's/.* LABEL="\([^"]*\)".*/\1/p'; }
mnt() { mkdir -p "$T/m"; mount -o ro "$LU" "$T/m"; }
umnt() { umount "$T/m"; }

echo "== status and check of a userdata with Android's data =="
# Android's userdata: here an ext4 without a label, with a file
mkfs.ext4 -q -F "$LU"; mkdir -p "$T/m"; mount "$LU" "$T/m"; echo android > "$T/m/a"; umount "$T/m"
eq "$(mig status)" "0" "status: exit 0"; eq "$(cat "$T/out")" "other" "status: other (Android's data)"
eq "$(mig check)" "0" "check: exit 0 (format may run)"
eq "$(cat "$T/out")" "other" "check prints the state"
S0=$(ud_sha)
eq "$(mig migrate --yes)" "1" "migrate before format: refused"
[ "$(ud_sha)" = "$S0" ] && ok "the refused migrate wrote nothing" || bad "the refused migrate wrote"
eq "$(mig format)" "2" "format without --yes: usage"
eq "$(mig migrate)" "2" "migrate without --yes: usage"

echo "== refusals of the preflight (nothing written) =="
refuse() {   # WHAT CMD... (before: setup; after: undo)
	w=$1; shift
	rc=$(mig "$@")
	if [ "$rc" = 1 ] && [ "$(ud_sha)" = "$S0" ]; then ok "refused, nothing written: $w"; else bad "$w (rc $rc, $(tail -n 1 "$T/err"))"; fi
}
mkdir -p "$T/m2"; mount -o ro "$LU" "$T/m2"; refuse "userdata mounted" format --yes; umount "$T/m2"
mkdir -p "$S/mmcblk0p28/holders/dm-0"; refuse "userdata held (dm)" format --yes; rmdir "$S/mmcblk0p28/holders/dm-0"
echo 1 > "$T/slotrc"; refuse "a RAM boot" format --yes; slot a 22
echo 2 > "$T/slotrc"; refuse "an unreadable slot" format --yes; slot a 22
slot a 23; refuse "slot A, but the root is system_b" format --yes; slot a 22
slot b 22; refuse "slot B, but the root is system_a" format --yes; slot a 22
echo "LABEL=tsxdata /data ext4 rw 0 0" >> "$T/fstab"; refuse "the running fstab mounts by label" format --yes
printf '# no label lines\ntmpfs /tmp tmpfs nosuid 0 0\n' > "$T/fstab"
echo 16811009 > "$S/mmcblk0p28/start"; refuse "userdata at another start" format --yes; echo 16811008 > "$S/mmcblk0p28/start"
echo 13724638 > "$S/mmcblk0p28/size"; refuse "userdata of another size" format --yes; echo $UD_SECT > "$S/mmcblk0p28/size"
echo SD > "$S/mmcblk0/device/type"; refuse "not an eMMC" format --yes; echo MMC > "$S/mmcblk0/device/type"
mv "$S/mmcblk0p28" "$S/mmcblk0p27"; ln -s "$LU" "$D/mmcblk0p27"; refuse "userdata on another partition number" format --yes
mv "$S/mmcblk0p27" "$S/mmcblk0p28"; rm "$D/mmcblk0p27"
( flock -n 9 && sleep 3 ) 9> "$T/run/uc-pxx-data.lock" & sleep 1; refuse "another run holds the lock" format --yes; wait
ab 15,0,1 14,0,1; refuse "the other slot (B) is not disabled (Android B still boots)" format --yes
ab 15,0,1 14,7,0; refuse "the other slot (B) is trying" format --yes
slot b 23; ab 0,0,0 15,0,1; rc=$(mig check); [ "$rc" = 0 ] && ok "slot B running, A disabled: check passes" || bad "slot B check (rc $rc, $(tail -n 1 "$T/err"))"
slot b 23; ab 15,0,1 14,0,1; refuse "slot B running, A not disabled" format --yes
slot a 22; ab 15,0,1 0,0,0

echo "== format =="
eq "$(mig format --yes)" "0" "format: exit 0"
eq "$(cat "$T/out")" "new" "format prints new"
eq "$(lab)" "tsxdata-new" "blkid: the label tsxdata-new"
eq "$(mig status)$(cat "$T/out")" "0new" "status: new"
mnt; [ -z "$(ls -A "$T/m" | grep -v lost+found)" ] && ok "the new file system is empty (Android's file is gone)" || bad "the new file system is not empty"; umnt
if command -v dumpe2fs > /dev/null; then
	eq "$(dumpe2fs -h "$LU" 2>/dev/null | sed -n 's/^Reserved block count: *//p')" "0" "no reserved blocks (-m 0)"
fi
eq "$(mig format --yes)" "0" "format of a tsxdata-new again: exit 0 (a cut run is formatted again)"

echo "== uc-pxx-lvm never mounts tsxdata-new =="
lvm_svc() {   # MOUNTPOINT: run the service with its OpenRC stand-ins
	( ebegin() { :; }; einfo() { :; }; eerror() { :; }; eend() { :; }; lvm() { return 5; }; modprobe() { :; }
	  UC_PXX_DATA_MNT=$1 UC_PXX_LVM_LOG=$T/lvm.log; . "$LVM"; start ) > /dev/null 2>&1
	awk -v m="$1" '$2 == m { print $1 }' /proc/mounts
}
mkdir -p "$T/data1" "$T/data2"
eq "$(lvm_svc "$T/data1")" "" "tsxdata-new: /data is not mounted"
eq "$(mig migrate)" "2" "migrate without --yes: usage (again)"

echo "== migrate without the Wi-Fi/Bluetooth files: refused =="
mv "$T/src/lib/firmware/brcm/BCM4345C5.hcd" "$T/bt.save"
S1=$(ud_sha)
eq "$(mig migrate --yes)" "1" "a missing vendor file: refused"
[ "$(ud_sha)" = "$S1" ] && [ "$(lab)" = tsxdata-new ] && ok "nothing written, still tsxdata-new" || bad "the refused migrate wrote"
mv "$T/bt.save" "$T/src/lib/firmware/brcm/BCM4345C5.hcd"

echo "== a migrate that fails at the last step (a cut before the label) =="
printf 'kiosk\nsyslog\n' > "$T/started"; : > "$T/rc.log"
eq "$(UC_PXX_SETLABEL=false mig migrate --yes)" "3" "the label step fails: exit 3"
eq "$(lab)" "tsxdata-new" "still tsxdata-new: nothing mounts it"
grep -q '^stop kiosk$' "$T/rc.log" && grep -q '^stop syslog$' "$T/rc.log" && ok "the running services were stopped" || bad "services not stopped ($(cat "$T/rc.log"))"
grep -q '^stop tsx-voice$' "$T/rc.log" && bad "a service that did not run was stopped" || ok "a service that did not run is left alone"
grep -q '^start kiosk$' "$T/rc.log" && grep -q '^start syslog$' "$T/rc.log" && ok "after the failure the services run again" || bad "services not started again"
eq "$(lvm_svc "$T/data1")" "" "after the failed run: /data is still not mounted"
mount "$LU" "$T/m"; echo junk > "$T/m/junk"; mkdir -p "$T/m/var/log"; echo stale > "$T/m/var/log/stale"; umount "$T/m"

echo "== a failure after the label: a finished /data (exit 4), the services stay stopped =="
cat > "$T/bin/label-then-fail" <<'LTF'
#!/bin/sh
python3 -I -c '
import fcntl, os, sys
fd = os.open(sys.argv[1], os.O_RDONLY | os.O_DIRECTORY)
fcntl.ioctl(fd, 0x41009432, sys.argv[2].encode() + bytes(256 - len(sys.argv[2])))
os.fsync(fd)' "$1" "$2"
exit 1
LTF
chmod 755 "$T/bin/label-then-fail"
mkfs.ext4 -q -F -L tsxdata-new "$LU"
printf 'kiosk\nsyslog\n' > "$T/started"; : > "$T/rc.log"
eq "$(UC_PXX_SETLABEL=$T/bin/label-then-fail mig migrate --yes)" "4" "the label set, then a failure: exit 4 (a finished /data, not 'run again')"
grep -q 'IS a finished /data' "$T/err" && ok "the message says it is finished" || bad "the message after the label ($(tail -n 1 "$T/err"))"
grep -q '^start ' "$T/rc.log" && bad "the services were started again after the label" || ok "the services stay stopped after the label"
mkfs.ext4 -q -F -L tsxdata-new "$LU"

echo "== migrate =="
SRC0=$(tdig "$T/src")
eq "$(mig migrate --yes)" "0" "migrate: exit 0"
eq "$(cat "$T/out")" "finished" "migrate prints finished"
eq "$(lab)" "tsxdata" "blkid: the label tsxdata"
eq "$(tdig "$T/src")" "$SRC0" "the running system's data is unchanged (nothing deleted or changed)"
mnt
[ ! -e "$T/m/junk" ] && [ ! -e "$T/m/var/log/stale" ] && ok "what the cut run left is gone" || bad "stale files of the cut run stayed"
eq "$(cat "$T/m/tsx/panel.conf")" "UPDATE_MODE=manual" "/data/tsx/panel.conf copied"
for d in var/lib/kiosk var/log var/lib/tsx root home; do
	[ -e "$T/m/$d/.tsx-moved" ] && ok "/$d: the marker of tsx-data" || bad "/$d: no marker"
	[ "$(cd "$T/m/$d" && find . ! -name .tsx-moved \( -type f -o -type l \) | sort | while read -r f; do [ -L "$f" ] && readlink "$f" || sha256sum < "$f"; done | sha256sum)" = \
	  "$(cd "$T/src/$d" && find . \( -type f -o -type l \) | sort | while read -r f; do [ -L "$f" ] && readlink "$f" || sha256sum < "$f"; done | sha256sum)" ] &&
		ok "/$d: the same files" || bad "/$d: the files differ"
done
eq "$(stat -c '%u:%g %a' "$T/m/var/lib/kiosk")" "100:101 750" "the owner and the mode of a folder are kept"
eq "$(stat -c '%a' "$T/m/root/.ssh/authorized_keys")" "600" "the mode of a file is kept"
eq "$(readlink "$T/m/var/lib/kiosk/profile/link")" "Prefs" "a symlink is kept"
[ -e "$T/m/var/lib/sendspin" ] && bad "a folder the root file system does not have was made" || ok "a folder the root file system does not have is left out"
eq "$(cat "$T/m/uc-pxx/firmware/fw_bcm43456c5_ag.bin")/$(cat "$T/m/uc-pxx/firmware/nvram_ap6256_FCC.txt")/$(cat "$T/m/uc-pxx/firmware/BCM4345C5.hcd")" "wifi/nvram/bt" "the three vendor files are in /data/uc-pxx/firmware"
grep -q '^from slot a (root system_a)' "$T/m/uc-pxx/data-migrate.txt" && ok "the record names the source slot" || bad "no record"
umnt
e2fsck -fn "$LU" > /dev/null 2>&1 && ok "e2fsck -fn: clean" || bad "e2fsck -fn finds problems"

echo "== a finished /data: every write refuses =="
S2=$(ud_sha)
eq "$(mig format --yes)" "4" "format of a finished /data: exit 4"
eq "$(mig migrate --yes)" "4" "migrate of a finished /data: exit 4"
eq "$(mig check)" "4" "check of a finished /data: exit 4"
mount -o ro "$LU" "$T/m2"; eq "$(mig format --yes)" "4" "format of a finished, mounted /data: exit 4 (not 1)"; umount "$T/m2"
[ "$(ud_sha)" = "$S2" ] && [ "$(lab)" = tsxdata ] && ok "nothing written" || bad "a refusal wrote"

echo "== both slots mount it (uc-pxx-lvm) =="
eq "$(lvm_svc "$T/data1")" "$D/mmcblk0p28" "the service mounts userdata (slot A's view)"
umount "$T/data1"
eq "$(lvm_svc "$T/data2")" "$D/mmcblk0p28" "the same service mounts the same userdata (slot B's view)"
umount "$T/data2"

echo "== resume: a userdata formatted again and migrated from slot B =="
mkfs.ext4 -q -F -L tsxdata-new "$LU"
slot b 23; ab 0,0,0 15,0,1
mksrc
# the phase-1 layout: tsx-data moved /var/log into /data before (marker), the
# root file system copy is empty
mkdir -p "$T/src/data/var/log"; echo "moved log" > "$T/src/data/var/log/messages"; : > "$T/src/data/var/log/.tsx-moved"; rm -f "$T/src/var/log/messages"
eq "$(mig migrate --yes)" "0" "migrate from slot B (root system_b): exit 0"
mnt
eq "$(cat "$T/m/var/log/messages")" "moved log" "a folder tsx-data moved before: the /data copy, not the empty root copy"
grep -q '^from slot b (root system_b)' "$T/m/uc-pxx/data-migrate.txt" && ok "the record names slot B" || bad "the record of slot B"
umnt
slot a 22; ab 15,0,1 0,0,0

echo "== uc-pxx-data-release: copy back, then wipe =="
mount "$LU" "$T/data1"
mount "$LR" "$T/m"; mkdir -p "$T/m/var/log" "$T/m/data"; echo old > "$T/m/var/log/messages"; umount "$T/m"
export UC_PXX_DATA=$T/data1
mkdir -p "$T/data1/var/lib/other"; echo keep > "$T/data1/var/lib/other/f"
: > "$T/vg"; eq "$(rel copy --yes)" "1" "release with the phase-1 volume group tsx: refused (its old /data would come back)"; rm -f "$T/vg"
eq "$(rel check)" "0" "release check: exit 0"
eq "$(rel wipe --yes)" "1" "wipe while userdata is tsxdata: refused"
eq "$(rel copy --yes)" "0" "release copy: exit 0"
umount "$T/data1"
eq "$(lab)" "tsxdata-old" "userdata has the label tsxdata-old"
eq "$(lvm_svc "$T/data1")" "" "tsxdata-old: /data is not mounted any more"
mount "$LR" "$T/m"
eq "$(cat "$T/m/var/log/messages")" "moved log" "the root file system has the data of /data again"
[ ! -e "$T/m/var/log/.tsx-moved" ] && ok "without the marker of tsx-data" || bad "the marker stayed on the root file system"
eq "$(cat "$T/m/data/tsx/panel.conf")" "UPDATE_MODE=manual" "/data/tsx/panel.conf is on the root file system"
[ ! -e "$T/m/data/var/log" ] && [ ! -e "$T/m/data/var/lib/kiosk" ] && ok "the moved folders are not copied twice under /data" || bad "moved folders under /data/var on the root file system"
eq "$(cat "$T/m/data/var/lib/other/f" 2>/dev/null)" "keep" "content under /data/var outside the tsx-data folders goes back to /data/var (R2-7)"
umount "$T/m"
eq "$(rel copy --yes)" "1" "copy again (userdata not tsxdata): refused"
eq "$(rel wipe --yes)" "0" "wipe: exit 0"
eq "$(blkid "$LU" | grep -c TYPE)" "0" "no file system on userdata"
eq "$(mig status)$(cat "$T/out")" "0other" "status: other"

echo "$N ok, $F failed"
[ "$F" = 0 ]
