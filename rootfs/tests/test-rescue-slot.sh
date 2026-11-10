#!/bin/sh
# Host test for the slot-aware rescue tools (MAINLINE-STEP2-DESIGN review F9):
# uc-pxx-findfs, the wrapper tsx-data-backup / tsx-data-restore, and the login
# of the rescue (tsx-rescue-login of tsx-linux-common, run with uc-pxx-findfs
# as rcS runs it). The rescue must act on the booted slot (system_a or
# system_b) or refuse, never on the first file system with a label. A
# made-up /sys/class/block, a stub blkid and stub mounts; no panel, no root.
# The common tools come from TSX_COMMON (default ../tsx-linux-common next to
# the repository); without them those parts print SKIPPED.
set -u
HERE=$(cd "$(dirname "$0")/.." && pwd)
REPO=$(cd "$HERE/.." && pwd)
COMMON=${TSX_COMMON:-$REPO/../tsx-linux-common}
OVL=$HERE/initramfs/overlay
FF=$OVL/usr/sbin/uc-pxx-findfs
WR=$OVL/usr/sbin/tsx-data-backup
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
N=0 F=0
ok()  { N=$((N + 1)); echo "  ok: $*"; }
bad() { F=$((F + 1)); echo "  FAIL: $*"; }
eq() { if [ "$1" = "$2" ]; then ok "$3"; else bad "$3 (got '$1', want '$2')"; fi; }
mkdir -p "$T/sys" "$T/dev" "$T/blkid" "$T/fs"

# part DEV NAME and fs DEV 'BLKID FIELDS': the made-up eMMC
part() { mkdir -p "$T/sys/$1"; echo "PARTNAME=$2" > "$T/sys/$1/uevent"; : > "$T/dev/$1"; }
fs() { echo "$2" > "$T/blkid/$1"; }
cat > "$T/blkid.sh" <<B
#!/bin/sh
f="$T/blkid/\${1##*/}"
[ -r "\$f" ] && { printf '%s: %s\n' "\$1" "\$(cat "\$f")"; exit 0; }
exit 2
B
printf '#!/bin/sh\n[ -e "%s/slotrc" ] && exit "$(cat "%s/slotrc")"\ncat "%s/slot"\n' "$T" "$T" "$T" > "$T/uc-pxx-slot"
chmod 755 "$T/blkid.sh" "$T/uc-pxx-slot"
slot() { echo "$1" > "$T/slot"; rm -f "$T/slotrc"; }
slotrc() { rm -f "$T/slot"; echo "$1" > "$T/slotrc"; }
export TSX_SYSBLOCK=$T/sys TSX_DEVDIR=$T/dev UC_PXX_SLOT=$T/uc-pxx-slot UC_PXX_BLKID=$T/blkid.sh
part mmcblk0p22 system_a; part mmcblk0p23 system_b; part mmcblk0p28 userdata
reset() {
	slot a
	fs mmcblk0p22 'LABEL="tsxroot" UUID="u" TYPE="ext4"'
	fs mmcblk0p23 'LABEL="tsxroot" UUID="u" TYPE="ext4"'
	fs mmcblk0p28 'TYPE="f2fs"'
}
ff() { out=$(sh "$FF" "$@"); echo "$?:$out"; }

echo "== uc-pxx-findfs =="
busybox sh -n "$FF" && ok "busybox sh -n" || bad "busybox sh -n"
[ -x "$FF" ] && ok "executable" || bad "not executable"
grep -v '^#' "$FF" | sed -e 's#[0-9]*>/dev/null##g' -e 's#>&2##g' | grep -Eq '>|\bdd\b|mkfs|e2label|tune2fs|\bmount\b' && bad "uc-pxx-findfs writes or mounts something" || ok "uc-pxx-findfs writes and mounts nothing"
reset; eq "$(ff LABEL=tsxroot)" "0:$T/dev/mmcblk0p22" "slot A, two tsxroot: system_a"
reset; slot b; eq "$(ff LABEL=tsxroot)" "0:$T/dev/mmcblk0p23" "slot B, two tsxroot: system_b, not the first one"
reset; slot b; fs mmcblk0p23 'LABEL="other" TYPE="ext4"'; eq "$(ff LABEL=tsxroot)" "1:" "slot B, system_b not tsxroot: nothing (never system_a)"
reset; slot b; fs mmcblk0p23 'LABEL="tsxroot" TYPE="ext3"'; eq "$(ff LABEL=tsxroot)" "1:" "slot B, system_b tsxroot on ext3: nothing"
reset; slotrc 1; eq "$(ff LABEL=tsxroot)" "1:" "a RAM boot (no slot): no root file system"
reset; slotrc 2; eq "$(ff LABEL=tsxroot)" "1:" "a slot that cannot be read: no root file system"
reset; slot c; eq "$(ff LABEL=tsxroot)" "1:" "uc-pxx-slot prints another slot: nothing"
reset; fs mmcblk0p28 'LABEL="tsxdata" UUID="d" TYPE="ext4"'; eq "$(ff LABEL=tsxdata)" "0:$T/dev/mmcblk0p28" "userdata ext4 tsxdata: /data"
reset; slotrc 1; fs mmcblk0p28 'LABEL="tsxdata" UUID="d" TYPE="ext4"'; eq "$(ff LABEL=tsxdata)" "0:$T/dev/mmcblk0p28" "a RAM boot still finds /data on userdata (both slots share it)"
reset; fs mmcblk0p28 'LABEL="tsxdata-new" UUID="d" TYPE="ext4"'; eq "$(ff LABEL=tsxdata)" "1:" "userdata tsxdata-new (step 2 not finished): nothing"
reset; eq "$(ff LABEL=tsxdata)" "1:" "Android's f2fs userdata: nothing"
reset; fs mmcblk0p24 'LABEL="tsxdata" TYPE="ext4"'; part mmcblk0p24 vendor_a; eq "$(ff LABEL=tsxdata)" "1:" "a tsxdata on another partition: nothing"
rm -rf "$T/sys/mmcblk0p24" "$T/blkid/mmcblk0p24" "$T/dev/mmcblk0p24"
reset; eq "$(ff LABEL=other)" "1:" "another label: nothing"
reset; eq "$(ff UUID=u)" "1:" "a UUID: nothing"
reset; eq "$(ff LABEL=tsxroot LABEL=tsxdata)" "1:" "two arguments: nothing"
reset; eq "$(ff)" "1:" "no argument: nothing"

echo "== the wrapper tsx-data-backup / tsx-data-restore =="
busybox sh -n "$WR" && ok "busybox sh -n" || bad "busybox sh -n"
[ -x "$WR" ] && ok "executable" || bad "not executable"
mkdir -p "$T/libexec" "$T/sbin"
printf '#!/bin/sh\necho "findfs=$TSX_DATA_FINDFS data=${TSX_DATA_LABEL-unset} root=${TSX_ROOTFS_LABEL-unset} args=$*"\n' > "$T/libexec/tsx-data-backup"
chmod 755 "$T/libexec/tsx-data-backup"
sed "s#/usr/libexec/tsx-rescue/#$T/libexec/#g" "$WR" > "$T/sbin/tsx-data-backup"; chmod 755 "$T/sbin/tsx-data-backup"
ln -s tsx-data-backup "$T/sbin/tsx-data-restore"
eq "$(TSX_DATA_LABEL=x TSX_ROOTFS_LABEL=y sh "$T/sbin/tsx-data-backup" - )" "findfs=/usr/sbin/uc-pxx-findfs data=unset root=unset args=-" "backup: runs the common tool with uc-pxx-findfs, the labels fixed"
eq "$(sh "$T/sbin/tsx-data-restore" --clean f.tgz)" "findfs=/usr/sbin/uc-pxx-findfs data=unset root=unset args=--restore --clean f.tgz" "restore (the link): --restore, with uc-pxx-findfs"
MK=$HERE/initramfs/mkinitramfs.sh
grep -q 'tsx-data-backup|tsx-data-restore) install -D -m 755 "$TSX_COMMON/rescue/usr/sbin/$f" $R/usr/libexec/tsx-rescue/$f;;' "$MK" && ok "mkinitramfs.sh puts the common data tools into /usr/libexec/tsx-rescue" || bad "the common data tools are not in /usr/libexec/tsx-rescue"
grep -q '^ln -sf tsx-data-backup $R/usr/sbin/tsx-data-restore$' "$MK" && ok "mkinitramfs.sh links tsx-data-restore to the wrapper" || bad "no tsx-data-restore link"
grep -q ' /usr/sbin/uc-pxx-findfs ' "$MK" && ok "mkinitramfs.sh checks uc-pxx-findfs" || bad "uc-pxx-findfs is not in the check list"
grep -q '^TSX_RESCUE_WAIT=0 TSX_RESCUE_FINDFS=/usr/sbin/uc-pxx-findfs /usr/sbin/tsx-rescue-login$' "$OVL/etc/init.d/rcS" && ok "rcS runs tsx-rescue-login with uc-pxx-findfs" || bad "rcS runs tsx-rescue-login without uc-pxx-findfs"

RL=$COMMON/rescue/usr/sbin/tsx-rescue-login
DB=$COMMON/rescue/usr/sbin/tsx-data-backup
if [ ! -f "$RL" ] || [ ! -f "$DB" ]; then
	echo "SKIPPED: no tsx-linux-common checkout (TSX_COMMON) for the login and backup runs"
	echo "$N ok, $F failed"; [ "$F" = 0 ]; exit
fi

echo "== the rescue login with uc-pxx-findfs (tsx-rescue-login of tsx-linux-common) =="
# the made-up file systems: a folder per device; mount copies it, umount empties
for d in mmcblk0p22 mmcblk0p23; do mkdir -p "$T/fs/$d/root/.ssh"; done
echo "ssh-ed25519 AAAAslotA a@x" > "$T/fs/mmcblk0p22/root/.ssh/authorized_keys"
echo "ssh-ed25519 AAAAslotB b@x" > "$T/fs/mmcblk0p23/root/.ssh/authorized_keys"
cat > "$T/mount.sh" <<M
#!/bin/sh
for a; do dev=\$dir; dir=\$a; done
[ -d "$T/fs/\${dev##*/}" ] || exit 32
cp -a "$T/fs/\${dev##*/}/." "\$dir/"
M
printf '#!/bin/sh\nrm -rf "$1"/* "$1"/.[!.]* 2>/dev/null; exit 0\n' > "$T/umount.sh"
chmod 755 "$T/mount.sh" "$T/umount.sh"
login() {
	rm -rf "$T/lroot" "$T/lrun"; mkdir -p "$T/lroot" "$T/lrun"
	printf 'root:*:19000:0:::::\n' > "$T/shadow"
	TSX_RESCUE_SHADOW=$T/shadow TSX_RESCUE_ROOT=$T/lroot TSX_RESCUE_RUN=$T/lrun TSX_RESCUE_WAIT=0 \
	TSX_RESCUE_FINDFS=$FF TSX_RESCUE_MOUNT=$T/mount.sh TSX_RESCUE_UMOUNT=$T/umount.sh \
	TSX_RESCUE_CHPASSWD="cat" TSX_RESCUE_URANDOM=/dev/urandom sh "$RL" > "$T/login.out" 2>&1
	cat "$T/lroot/.ssh/authorized_keys" 2>/dev/null | tr '\n' ' '; echo ":$(cat "$T/lrun/tsx-rescue-login")"
}
FF="sh $FF"
reset; eq "$(login)" "ssh-ed25519 AAAAslotA a@x :panel" "slot A: the key of system_a only"
reset; slot b; eq "$(login)" "ssh-ed25519 AAAAslotB b@x :panel" "slot B: the key of system_b only, never system_a's"
reset; slotrc 1; eq "$(login)" ":onetime" "a RAM boot: no root file system, a one-time password"
reset; slotrc 2; eq "$(login)" ":onetime" "a slot that cannot be read: a one-time password"

echo "== the data backup with uc-pxx-findfs (tsx-data-backup of tsx-linux-common) =="
# The common tool prints the device it chose before it reads the data; the
# stub mount gives it an empty tree, so it then stops with "no panel data".
mkdir -p "$T/fs/mmcblk0p28"
cat > "$T/mount2.sh" <<'M'
#!/bin/sh
exit 0
M
chmod 755 "$T/mount2.sh"
bk() {
	: > "$T/mounts"
	TSX_DATA_FINDFS="$FF" TSX_DATA_MOUNT=$T/mount2.sh TSX_DATA_UMOUNT=true TSX_DATA_MOUNTS=$T/mounts TSX_DATA_RUN=$T/drun \
		sh "$DB" - > /dev/null 2> "$T/bk.err"
	sed -n 's/^tsx-data-backup: backup: \([^ ]*\) .*/\1/p' "$T/bk.err"
	grep -q 'ERROR: no file system' "$T/bk.err" && echo refused
}
mkdir -p "$T/drun"
reset; eq "$(bk)" "$T/dev/mmcblk0p22" "slot A, no /data: the root file system of system_a"
reset; slot b; eq "$(bk)" "$T/dev/mmcblk0p23" "slot B, no /data: the root file system of system_b"
reset; slot b; fs mmcblk0p28 'LABEL="tsxdata" TYPE="ext4"'; eq "$(bk)" "$T/dev/mmcblk0p28" "slot B, /data on userdata: userdata"
reset; slotrc 1; eq "$(bk)" "refused" "a RAM boot, no /data: refused (no file system)"
reset; slot b; fs mmcblk0p28 'LABEL="tsxdata-new" TYPE="ext4"'; eq "$(bk)" "$T/dev/mmcblk0p23" "slot B, userdata tsxdata-new: never userdata, the root of system_b"

echo "$N ok, $F failed"
[ "$F" = 0 ]
