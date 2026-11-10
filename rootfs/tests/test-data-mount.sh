#!/bin/sh
# Host test for the service uc-pxx-lvm (rootfs/overlay/etc/init.d/uc-pxx-lvm):
# which file system becomes /data (MAINLINE-STEP2-DESIGN §6.2 L6, review F7).
# The service runs with stub OpenRC functions and stub blkid, mount, lvm and
# modprobe, against a made-up /sys/class/block. Needs no panel and no root.
# Run it with busybox sh or a POSIX sh.
set -u
HERE=$(cd "$(dirname "$0")/.." && pwd)
SVC=$HERE/overlay/etc/init.d/uc-pxx-lvm
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
N=0 F=0
ok()  { N=$((N + 1)); echo "  ok: $*"; }
bad() { F=$((F + 1)); echo "  FAIL: $*"; }
mkdir -p "$T/bin" "$T/sys" "$T/dev/tsx"

# stubs: blkid DEV prints $T/blkid/<name of DEV> (the busybox format); mount
# records its arguments and adds the mount to $T/mounts; lvm follows $T/lvm
# ("none": no volume group, "fail": vgchange fails, else the group exists)
cat > "$T/bin/blkid" <<EOF
#!/bin/sh
f="$T/blkid/\$(echo "\$1" | tr / _)"
[ -r "\$f" ] && { printf '%s: %s\n' "\$1" "\$(cat "\$f")"; exit 0; }
exit 2
EOF
cat > "$T/bin/mount" <<EOF
#!/bin/sh
echo "\$*" >> "$T/mount.log"
[ -e "$T/mount-fails" ] && exit 32
for a; do dev=\$mnt; mnt=\$a; done
echo "\$dev \$mnt ext4 rw 0 0" >> "$T/mounts"
EOF
cat > "$T/bin/lvm" <<EOF
#!/bin/sh
echo "lvm \$*" >> "$T/lvm.log"
case "\$(cat "$T/lvm" 2>/dev/null)" in
none) exit 5;;
fail) [ "\$1" = vgs ] && exit 0; exit 5;;
esac
exit 0
EOF
printf '#!/bin/sh\nexit 0\n' > "$T/bin/modprobe"
chmod 755 "$T"/bin/*

# part NAME DEV: a partition of the made-up eMMC
part() { mkdir -p "$T/sys/$2"; echo "PARTNAME=$1" > "$T/sys/$2/uevent"; }
fs() { mkdir -p "$T/blkid"; echo "$2" > "$T/blkid/$(echo "$1" | tr / _)"; }
reset() {
	rm -rf "$T/sys"/* "$T/blkid" "$T/mount.log" "$T/lvm.log" "$T/mount-fails"; : > "$T/mounts"; echo none > "$T/lvm"
	part userdata mmcblk0p28; part vendor_a mmcblk0p24; part system_a mmcblk0p22
}
svc() {
	( PATH="$T/bin:$PATH"
	  TSX_SYSBLOCK=$T/sys TSX_DEVDIR=$T/dev UC_PXX_DATA_MNT=/data UC_PXX_MOUNTS=$T/mounts UC_PXX_LVM_LOG=$T/lvm-svc.log
	  export PATH TSX_SYSBLOCK TSX_DEVDIR UC_PXX_DATA_MNT UC_PXX_MOUNTS UC_PXX_LVM_LOG
	  ebegin() { :; }; einfo() { echo "einfo $*" >> "$T/out"; }; eerror() { echo "eerror $*" >> "$T/out"; }
	  eend() { echo "eend $1" >> "$T/out"; }
	  # functions, so busybox sh does not run its own applets of these names
	  blkid() { "$T/bin/blkid" "$@"; }; mount() { "$T/bin/mount" "$@"; }; modprobe() { :; }
	  . "$SVC"; start ) > "$T/svc.out" 2>&1
	echo $?
}
mounted() { awk '$2 == "/data" { print $1 }' "$T/mounts"; }

echo "== uc-pxx-lvm: the source of /data =="
sh -n "$SVC" && ok "the service passes sh -n" || bad "sh -n"
reset; fs "$T/dev/mmcblk0p28" 'LABEL="tsxdata" UUID="1" TYPE="ext4"'; echo vg > "$T/lvm"
rc=$(svc)
{ [ "$rc" = 0 ] && [ "$(mounted)" = "$T/dev/mmcblk0p28" ] && [ ! -e "$T/lvm.log" ]; } && ok "userdata ext4 tsxdata: /data = userdata, the volume group is never touched" || bad "userdata tsxdata (rc $rc, mounted '$(mounted)')"
grep -q -- '-t ext4 -o rw,noatime,commit=60 ' "$T/mount.log" && ok "the mount options rw,noatime,commit=60" || bad "the mount options ($(cat "$T/mount.log"))"
reset; fs "$T/dev/mmcblk0p28" 'LABEL="tsxdata-new" UUID="1" TYPE="ext4"'
rc=$(svc)
{ [ "$rc" = 0 ] && [ -z "$(mounted)" ]; } && ok "userdata tsxdata-new (step 2 not finished): never mounted" || bad "tsxdata-new was mounted ('$(mounted)')"
reset; fs "$T/dev/mmcblk0p28" 'TYPE="f2fs"'
rc=$(svc)
{ [ "$rc" = 0 ] && [ -z "$(mounted)" ]; } && ok "Android's f2fs userdata: never mounted" || bad "Android's userdata was mounted"
reset; fs "$T/dev/mmcblk0p28" 'UUID="1" TYPE="ext4"'
rc=$(svc)
{ [ "$rc" = 0 ] && [ -z "$(mounted)" ]; } && ok "an ext4 userdata without a label (Android): never mounted" || bad "an ext4 userdata without a label was mounted"
reset; fs "$T/dev/mmcblk0p28" 'LABEL="tsxdata" UUID="1" TYPE="ext3"'
rc=$(svc)
{ [ "$rc" = 0 ] && [ -z "$(mounted)" ]; } && ok "the label tsxdata on ext3: never mounted" || bad "a non-ext4 tsxdata was mounted"
reset; fs "$T/dev/mmcblk0p28" 'LABEL="xtsxdata" UUID="1" TYPE="ext4"'
rc=$(svc)
{ [ "$rc" = 0 ] && [ -z "$(mounted)" ]; } && ok "a label that only contains tsxdata: never mounted" || bad "label xtsxdata was mounted"
reset; echo vg > "$T/lvm"; fs "$T/dev/tsx/data" 'LABEL="tsxdata" UUID="2" TYPE="ext4"'; fs "$T/dev/mmcblk0p28" 'TYPE="f2fs"'
rc=$(svc)
{ [ "$rc" = 0 ] && [ "$(mounted)" = "$T/dev/tsx/data" ] && grep -q 'vgchange -a y --sysinit tsx' "$T/lvm.log"; } && ok "phase 1: the volume group activated, tsx/data on /data" || bad "phase 1 (rc $rc, '$(mounted)')"
reset; echo vg > "$T/lvm"; fs "$T/dev/tsx/data" 'LABEL="other" UUID="2" TYPE="ext4"'
rc=$(svc)
{ [ "$rc" = 0 ] && [ -z "$(mounted)" ]; } && ok "phase 1, a volume without the label tsxdata: not mounted" || bad "a wrong LVM volume was mounted"
reset; echo vg > "$T/lvm"; fs "$T/dev/tsx/data" 'LABEL="tsxdata" UUID="2" TYPE="ext4"'; fs "$T/dev/mmcblk0p28" 'LABEL="tsxdata" UUID="1" TYPE="ext4"'
rc=$(svc)
{ [ "$rc" = 0 ] && [ "$(mounted)" = "$T/dev/mmcblk0p28" ] && [ ! -e "$T/lvm.log" ]; } && ok "two tsxdata (userdata and the LVM volume): userdata only, the group stays inactive" || bad "two tsxdata (rc $rc, '$(mounted)')"
reset; echo fail > "$T/lvm"
rc=$(svc)
{ [ "$rc" = 0 ] && [ -z "$(mounted)" ]; } && ok "vgchange fails: nothing mounted, the boot goes on" || bad "vgchange failure (rc $rc)"
reset; rc=$(svc)
{ [ "$rc" = 0 ] && [ -z "$(mounted)" ]; } && ok "no tsxdata anywhere: nothing mounted, the boot goes on" || bad "nothing to mount (rc $rc)"
reset; fs "$T/dev/mmcblk0p28" 'LABEL="tsxdata" UUID="1" TYPE="ext4"'; echo "/dev/other /data ext4 rw 0 0" > "$T/mounts"
rc=$(svc)
{ [ "$rc" = 0 ] && [ ! -e "$T/mount.log" ]; } && ok "/data mounted already: no second mount over it" || bad "a second mount over /data"
reset; fs "$T/dev/mmcblk0p28" 'LABEL="tsxdata" UUID="1" TYPE="ext4"'; : > "$T/mount-fails"
rc=$(svc)
[ "$rc" = 0 ] && ok "a failed mount does not fail the boot" || bad "a failed mount failed the service (rc $rc)"
reset; rm -rf "$T/sys/mmcblk0p28"; echo vg > "$T/lvm"; fs "$T/dev/tsx/data" 'LABEL="tsxdata" UUID="2" TYPE="ext4"'
rc=$(svc)
{ [ "$rc" = 0 ] && [ "$(mounted)" = "$T/dev/tsx/data" ]; } && ok "no partition named userdata: phase 1 as before" || bad "no userdata partition (rc $rc)"
grep -q '^	before localmount fsck tsx-data$' "$SVC" && ok "the service runs before localmount and tsx-data" || bad "the order of the service changed"

echo "$N ok, $F failed"
[ "$F" = 0 ]
