#!/bin/sh
# Host test for uc-pxx-slot (rootfs/overlay/usr/sbin/uc-pxx-slot) and for the
# places that use it: the initramfs (/init picks system_a or system_b) and
# mkinitramfs.sh (it installs the program). MAINLINE-STEP2-DESIGN §10 L1, L2.
# Needs no panel and no compiler. Run it with busybox sh or a POSIX sh.
set -u
HERE=$(cd "$(dirname "$0")/.." && pwd)
SLOT=$HERE/overlay/usr/sbin/uc-pxx-slot
INIT=$HERE/initramfs/overlay/init
MK=$HERE/initramfs/mkinitramfs.sh
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
N=0 F=0
ok()  { N=$((N + 1)); echo "  ok: $*"; }
bad() { F=$((F + 1)); echo "  FAIL: $*"; }
eq() { if [ "$1" = "$2" ]; then ok "$3"; else bad "$3 (got '$1', want '$2')"; fi; }

echo "== uc-pxx-slot =="
sh -n "$SLOT" && ok "uc-pxx-slot passes sh -n" || bad "uc-pxx-slot: sh -n"
[ -x "$SLOT" ] && ok "uc-pxx-slot is executable" || bad "uc-pxx-slot is not executable"
grep -q '^P=/proc/device-tree/chosen/u-boot,bootargs$' "$SLOT" && ok "it reads only /proc/device-tree/chosen/u-boot,bootargs" || bad "the property path changed"
grep -v '^#' "$SLOT" | grep -Eq '>[^&]|\bdd\b|\btee\b' && bad "uc-pxx-slot writes something" || ok "uc-pxx-slot writes nothing"
sed "s#/proc/device-tree/chosen/u-boot,bootargs#$T/prop#" "$SLOT" > "$T/slot"
run() { out=$(sh "$T/slot"); rc=$?; echo "$rc:$out"; }
prop() { printf '%s\000' "$1" > "$T/prop"; }
# the measured U-Boot command line of a UC-P10 (docs/boot.md), slot words changed per case
UB='storagemedia=emmc androidboot.mode=normal lcdid=1 fuse.programmed=1 androidboot.verifiedbootstate=orange skip_initramfs'
UE='androidboot.serialno=X console=ttyFIQ0 rdinit=/init rootfstype=ext4'
prop "$UB androidboot.slot_suffix=_a $UE"; eq "$(run)" "0:a" "slot _a prints a"
prop "$UB androidboot.slot_suffix=_b $UE"; eq "$(run)" "0:b" "slot _b prints b"
prop "androidboot.slot_suffix=_b"; eq "$(run)" "0:b" "the word alone"
printf '%s\tandroidboot.slot_suffix=_a\t%s\000' "$UB" "$UE" > "$T/prop"; eq "$(run)" "0:a" "words split by tabs"
rm -f "$T/prop"; eq "$(run)" "1:" "no property (a RAM boot): exit 1, nothing printed"
prop "$UB $UE"; eq "$(run)" "2:" "no slot word: exit 2"
prop "$UB androidboot.slot_suffix=_a androidboot.slot_suffix=_b $UE"; eq "$(run)" "2:" "two slot words (a and b): exit 2"
prop "$UB androidboot.slot_suffix=_a androidboot.slot_suffix=_a $UE"; eq "$(run)" "2:" "two slot words (a and a): exit 2"
prop "$UB androidboot.slot_suffix=_c $UE"; eq "$(run)" "2:" "slot _c: exit 2"
prop "$UB androidboot.slot_suffix=a $UE"; eq "$(run)" "2:" "slot without the underscore: exit 2"
prop "$UB androidboot.slot_suffix= $UE"; eq "$(run)" "2:" "empty slot: exit 2"
prop "$UB androidboot.slot_suffix=_ab $UE"; eq "$(run)" "2:" "slot _ab: exit 2"
prop "$UB xandroidboot.slot_suffix=_b $UE"; eq "$(run)" "2:" "a longer word that ends like the slot word: exit 2"
prop "$UB androidboot.slot_suffix=_b"; printf 'androidboot.slot_suffix=_a\000' >> "$T/prop"; eq "$(run)" "2:" "a second string after the NUL: two words, exit 2"
: > "$T/prop"; eq "$(run)" "2:" "an empty property: exit 2"

echo "== the initramfs =="
sh -n "$INIT" && ok "init passes sh -n" || bad "init: sh -n"
grep -q '^slot=$(/usr/sbin/uc-pxx-slot 2>/dev/null); src=$?$' "$INIT" && ok "init asks uc-pxx-slot for the booted slot" || bad "init does not run uc-pxx-slot"
sed -n '/^slot=$(\/usr\/sbin\/uc-pxx-slot/,/^esac$/p' "$INIT" > "$T/slotcase"
grep -q '^1) slot= ;;$' "$T/slotcase" && ok "uc-pxx-slot exit 1 (no u-boot,bootargs: a RAM boot): no slot" || bad "exit 1 is not the RAM boot"
grep -q '^\*) rescue ' "$T/slotcase" && ok "any other exit of uc-pxx-slot (a bad slot word): the rescue" || bad "a bad slot word does not start the rescue"
grep -q '^rootname=system_${slot:-a}$' "$INIT" && ok "the root partition is system_<slot>, system_a without a slot (a RAM boot)" || bad "the root partition rule changed"
grep -q 'part_by_name "$rootname"' "$INIT" && ok "find_root looks for the GPT name of the booted slot" || bad "find_root does not use the booted slot"
grep -q 'part_by_name system_a' "$INIT" && bad "init still looks for system_a by name" || ok "no fixed system_a lookup is left"
grep -v '^[[:space:]]*#' "$INIT" | grep -Eq 'findfs|LABEL=tsxroot|UUID=' && bad "init still finds a root by a label or a UUID" || ok "init never finds a root by a label or a UUID (F7)"
grep -q '^mount -t ext4 -o rw,noatime,commit=60 "$dev" /newroot ' "$INIT" && ok "init mounts the root with rw,noatime,commit=60 (the options of the old fstab line)" || bad "the root mount options changed"
grep -v '^#' "$HERE/overlay/etc/fstab" | grep -Eq '(LABEL|UUID|PARTUUID|PARTLABEL)=' && bad "the fstab still mounts by a label or a UUID" || ok "the fstab mounts nothing by a label or a UUID (F7)"
grep -v '^#' "$HERE/overlay/etc/fstab" | awk '$2 == "/" || $2 == "/data"' | grep -q . && bad "the fstab has a root or a /data line" || ok "the fstab has no root and no /data line"
# find_root of init, run with stand-ins: part_by_name finds the slot's partition
sed -n '/^# find_root: the device of the partition with the GPT name/,/^}$/p' "$INIT" > "$T/find_root.sh"
cat > "$T/rig.sh" <<'RIG'
part_by_name() { for n in $PARTS; do [ "$n" = "$1" ] && { echo "/dev/blk-$1"; return 0; }; done; return 1; }
blkid() { printf '%s' "$BLKID"; }
findfs() { [ -n "$FINDFS" ] && echo "$FINDFS"; }
RIG
cat "$T/find_root.sh" >> "$T/rig.sh"
# [ -b ] is true only for block devices: stand in with a function
sed -i 's/\[ -b "\$d" \]/isblk "$d"/' "$T/rig.sh"
echo 'isblk() { case $1 in /dev/blk-*) return 0;; esac; return 1; }; find_root' >> "$T/rig.sh"
[ -s "$T/find_root.sh" ] && ok "find_root found in init" || bad "find_root not found in init"
fr() { rootname=$1 PARTS=$2 BLKID=$3 FINDFS=$4 slot=${5-} sh "$T/rig.sh"; echo ":$?"; }
two='/dev/mmcblk0p22: LABEL="tsxroot" TYPE="ext4"
/dev/mmcblk0p23: LABEL="tsxroot" TYPE="ext4"
'
one='/dev/mmcblk0p22: LABEL="tsxroot" TYPE="ext4"
'
eq "$(fr system_b "system_a system_b" "$two" /dev/mmcblk0p22 b)" "/dev/blk-system_b
:0" "slot B: the partition named system_b, not the first tsxroot"
eq "$(fr system_b "system_a" "$one" /dev/mmcblk0p22 b)" ":1" "slot B, system_b not there yet and one tsxroot (p22): no root (wait), never system_a"
eq "$(fr system_a "" "$one" /dev/mmcblk0p22 a)" ":1" "slot A without the GPT name: no label fallback"
eq "$(fr system_a "system_a system_b" "$two" /dev/mmcblk0p23 a)" "/dev/blk-system_a
:0" "slot A: the partition named system_a"
eq "$(fr system_b "" "$two" /dev/mmcblk0p22)" ":1" "no GPT name and two tsxroot: no root (the rescue), never a guess"
eq "$(fr system_a "" "$one" /dev/mmcblk0p22)" ":1" "a RAM boot, no GPT name, one tsxroot: no root (no label fallback any more, F7)"
eq "$(fr system_a "system_a" "$one" /dev/mmcblk0p23)" "/dev/blk-system_a
:0" "a RAM boot: the partition named system_a"

echo "== mkinitramfs.sh =="
grep -q '^install -D -m 755 /w/rootfs/overlay/usr/sbin/uc-pxx-slot $R/usr/sbin/uc-pxx-slot$' "$MK" && ok "mkinitramfs.sh installs uc-pxx-slot" || bad "mkinitramfs.sh does not install uc-pxx-slot"
grep -q ' /usr/sbin/uc-pxx-slot ' "$MK" && ok "mkinitramfs.sh checks that uc-pxx-slot is in the initramfs" || bad "uc-pxx-slot is not in the check list"

echo "$N ok, $F failed"
[ "$F" = 0 ]
