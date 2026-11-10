#!/bin/sh
# Host test for the boot-marking hook (rootfs/overlay/etc/uc-pxx-mark-boot.sh)
# and for uc-pxx-arm-slot. The scripts run from a copy whose fixed paths point
# into a temporary directory. They use the real uc-pxx-bootctl on a sector
# file, so this test needs a program that runs on the host:
#   UC_PXX_BOOTCTL_RUN="qemu-aarch64-static /path/uc-pxx-bootctl-aarch64" sh rootfs/tests/test-mark-boot.sh
# Without the variable it prints SKIPPED and exits 0. Needs python3 and flock.
set -u
HERE=$(cd "$(dirname "$0")/.." && pwd)
HOOK=$HERE/overlay/etc/uc-pxx-mark-boot.sh
ARM=$HERE/overlay/usr/sbin/uc-pxx-arm-slot
FLASH=$HERE/overlay/usr/sbin/uc-pxx-flash-boot
[ -n "${UC_PXX_BOOTCTL_RUN:-}" ] || { echo "SKIPPED: UC_PXX_BOOTCTL_RUN is not set"; exit 0; }
for t in python3 flock; do command -v "$t" >/dev/null 2>&1 || { echo "SKIPPED: $t is not installed"; exit 0; }; done
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
N=0 F=0
ok()  { N=$((N + 1)); echo "  ok: $*"; }
bad() { F=$((F + 1)); echo "  FAIL: $*"; }
mkdir -p "$T/run" "$T/etc" "$T/bin"

# the scripts with their fixed paths moved into $T
for s in HOOK ARM; do
	eval "src=\$$s"
	sed -e "s#/run/#$T/run/#g" -e "s#/etc/#$T/etc/#g" -e "s#/proc/cmdline#$T/cmdline#g" \
	    -e "s#/proc/uptime#$T/uptime#g" -e "s#/proc/sys/kernel/tainted#$T/tainted#g" \
	    -e "s#/dev/kmsg#$T/kmsg#g" -e "s#/sys/class/#$T/sys/#g" -e "s#/usr/sbin/uc-pxx-bootctl#$T/bin/uc-pxx-bootctl#g" \
	    -e "s#/usr/sbin/uc-pxx-slot#$T/bin/uc-pxx-slot#g" -e "s#/proc/self/mountinfo#$T/mountinfo#g" \
	    -e 's/^NET_WAIT_SECS=300/NET_WAIT_SECS=0/' "$src" > "$T/$s.sh"
done
printf '#!/bin/sh\nexec %s "$@" --file %s/sector --boot-file %s/boot.img\n' "$UC_PXX_BOOTCTL_RUN" "$T" "$T" > "$T/bin/uc-pxx-bootctl"
# the real uc-pxx-slot, reading $T/ubootargs (the stand-in of /proc/device-tree/chosen/u-boot,bootargs).
# boot.img is the stand-in of the boot partition of the slot that the hook expects.
sed "s#/proc/device-tree/chosen/u-boot,bootargs#$T/ubootargs#g" "$HERE/overlay/usr/sbin/uc-pxx-slot" > "$T/bin/uc-pxx-slot"
printf '#!/bin/sh\necho "    inet 192.0.2.10/24"\n' > "$T/bin/ip"
printf '#!/bin/sh\n[ -e "%s/sshd-up" ]\n' "$T" > "$T/bin/pidof"
chmod 755 "$T"/bin/*
echo "100.00 100.00" > "$T/uptime"; echo 0 > "$T/tainted"

# sector A B: "prio,tries,succ" for each slot, valid CRC (big-endian)
mksector() {
	python3 -I - "$T/sector" "$1" "$2" <<'PY'
import binascii, sys
b = bytearray(512)
b[:4] = b"\0AB0"; b[4] = 1
b[8:11] = bytes(int(x) for x in sys.argv[2].split(","))
b[12:15] = bytes(int(x) for x in sys.argv[3].split(","))
b[28:32] = (binascii.crc32(bytes(b[:28])) & 0xffffffff).to_bytes(4, "big")
open(sys.argv[1], "wb").write(b)
PY
}
mkboot() {
	python3 -I - "$T/boot.img" "$1" <<'PY'
import sys
h = bytearray(4096); h[:8] = b"ANDROID!"; h[48:48 + len(sys.argv[2])] = sys.argv[2].encode()
open(sys.argv[1], "wb").write(h)
PY
}
# ubootargs SUFFIX...: the U-Boot command line with these androidboot.slot_suffix words
ubootargs() {
	{ printf 'storagemedia=emmc androidboot.mode=normal'; for x in "$@"; do printf ' androidboot.slot_suffix=%s' "$x"; done
	  printf ' console=ttyFIQ0\000'; } > "$T/ubootargs"
}
# root DEV: the running root file system is DEV (179:22 = system_a, 179:23 = system_b)
root() { printf '22 1 %s / / rw,noatime shared:1 - ext4 /dev/root rw\n' "$1" > "$T/mountinfo"; }
mkdir -p "$T/sys/block/mmcblk0p22" "$T/sys/block/mmcblk0p23"
echo PARTNAME=system_a > "$T/sys/block/mmcblk0p22/uevent"; echo 179:22 > "$T/sys/block/mmcblk0p22/dev"
echo PARTNAME=system_b > "$T/sys/block/mmcblk0p23/uevent"; echo 179:23 > "$T/sys/block/mmcblk0p23/dev"
# reset: A trying {15,7,0}, B successful {14,0,1}, boot_a token tok1, U-Boot started slot A, root system_a,
# healthy system
reset() {
	mksector 15,7,0 14,0,1; mkboot tok1; ubootargs _a; root 179:22
	echo 0 > "$T/tainted"
	echo "console=ttyS2,115200n8 rdinit=/init uc-pxx.id=tok1" > "$T/cmdline"
	rm -f "$T/run/"* "$T/etc/uc-pxx-nomark" "$T/etc/uc-pxx-build-id"; : > "$T/sshd-up"
}
marked() { [ "$(od -An -tu1 -j8 -N3 "$T/sector" | tr -s ' ')" = " 15 0 1" ]; }
ab() { od -An -tu1 -j8 -N8 "$T/sector" | tr -s ' '; }
unchanged() { [ "$(od -An -tu1 -j8 -N3 "$T/sector" | tr -s ' ')" = " 15 7 0" ]; }
hook() { PATH="$T/bin:$PATH" sh "$T/HOOK.sh" >/dev/null 2>&1; }

echo "== the hook =="
reset; hook; rc=$?
{ [ $rc = 0 ] && marked; } && ok "a command line token that equals the boot_a header marks A" || bad "no mark with a matching token (rc $rc)"
reset; echo "console=ttyS2 uc-pxx.id=tok2" > "$T/cmdline"; hook; rc=$?
{ [ $rc = 1 ] && unchanged; } && ok "a command line token that differs from the header: no mark" || bad "marked with a wrong token (rc $rc)"
reset; echo "console=ttyS2 rdinit=/init" > "$T/cmdline"; hook; rc=$?
{ [ $rc = 1 ] && unchanged; } && ok "no token on the command line: no mark" || bad "marked without a token (rc $rc)"
reset; echo "console=ttyS2 rdinit=/init" > "$T/cmdline"; echo tok1 > "$T/etc/uc-pxx-build-id"; hook; rc=$?
{ [ $rc = 1 ] && unchanged; } && ok "a token only in the root file system: no mark" || bad "marked from a file of the root file system (rc $rc)"
grep -q 'build-id' "$HOOK" && grep -v '^#' "$HOOK" | grep -q 'build-id' && bad "the hook code reads a build-id file" || ok "the hook code has no build-id file"
reset; touch "$T/run/uc-pxx-slot-a-changed"; hook; rc=$?
{ [ $rc = 1 ] && unchanged; } && ok "the marker uc-pxx-slot-a-changed: no mark" || bad "marked with the marker present (rc $rc)"
reset; echo "uc-pxx.id=tok1 uc-pxx.nomark" > "$T/cmdline"; hook; rc=$?
{ [ $rc = 0 ] && unchanged; } && ok "uc-pxx.nomark: A left as it is" || bad "uc-pxx.nomark did not hold (rc $rc)"
reset; touch "$T/etc/uc-pxx-nomark"; hook; rc=$?
{ [ $rc = 0 ] && unchanged; } && ok "/etc/uc-pxx-nomark: A left as it is" || bad "/etc/uc-pxx-nomark did not hold (rc $rc)"
reset; rm -f "$T/sshd-up"; hook; rc=$?
{ [ $rc = 1 ] && unchanged; } && ok "no sshd: no mark" || bad "marked without sshd (rc $rc)"
reset; echo 128 > "$T/tainted"; hook; rc=$?
{ [ $rc = 1 ] && unchanged; } && ok "kernel oops (taint bit 7): no mark" || bad "marked after an oops (rc $rc)"
reset; ( flock -n 9 && sleep 5 ) 9> "$T/run/uc-pxx-abdata.lock" & sleep 1
hook; rc=$?; wait
{ [ $rc = 1 ] && unchanged; } && ok "lock held by another program: no mark" || bad "marked while the lock was held (rc $rc)"

echo "== the hook, both slots (MAINLINE-STEP2-DESIGN §10 L3) =="
# B started trying after step 2, A the successful fallback; boot.img stands for boot_b
reset; mksector 14,0,1 15,7,0; ubootargs _b; hook; rc=$?
{ [ $rc = 0 ] && [ "$(ab)" = " 14 0 1 0 15 0 1 0" ]; } && ok "slot B started: B marked, A unchanged" || bad "slot B not marked (rc $rc, $(ab))"
reset; mksector 14,0,1 15,7,0; ubootargs _b; mkboot tok2; hook; rc=$?
{ [ $rc = 1 ] && [ "$(ab)" = " 14 0 1 0 15 7 0 0" ]; } && ok "slot B started, boot_b holds another token: no mark" || bad "marked B with a wrong token (rc $rc)"
reset; rm -f "$T/ubootargs"; hook; rc=$?
{ [ $rc = 1 ] && unchanged; } && ok "no u-boot,bootargs (a RAM boot): no mark" || bad "marked without a slot (rc $rc)"
reset; ubootargs; hook; rc=$?
{ [ $rc = 1 ] && unchanged; } && ok "u-boot,bootargs without androidboot.slot_suffix: no mark" || bad "marked without a slot word (rc $rc)"
reset; ubootargs _a _a; hook; rc=$?
{ [ $rc = 1 ] && unchanged; } && ok "two androidboot.slot_suffix words: no mark" || bad "marked with two slot words (rc $rc)"
reset; ubootargs _c; hook; rc=$?
{ [ $rc = 1 ] && unchanged; } && ok "androidboot.slot_suffix=_c: no mark" || bad "marked with slot _c (rc $rc)"
reset; ubootargs _b; hook; rc=$?
{ [ $rc = 1 ] && unchanged; } && ok "U-Boot says B, but libavb would start A: uc-pxx-bootctl refuses" || bad "marked against the A/B state (rc $rc)"
reset; mksector 14,0,1 15,7,0; hook; rc=$?
{ [ $rc = 1 ] && [ "$(ab)" = " 14 0 1 0 15 7 0 0" ]; } && ok "U-Boot says A, but libavb would start B: no mark" || bad "marked A while B is the pick (rc $rc)"
reset; mksector 14,0,1 15,7,0; ubootargs _b; touch "$T/run/uc-pxx-slot-a-changed"; hook; rc=$?
{ [ $rc = 0 ] && [ "$(ab)" = " 14 0 1 0 15 0 1 0" ]; } && ok "slot B started: the marker of slot A does not stop the mark of B" || bad "the A marker stopped B (rc $rc)"
reset; mksector 14,0,1 15,7,0; ubootargs _b; touch "$T/run/uc-pxx-slot-b-changed"; hook; rc=$?
{ [ $rc = 1 ] && [ "$(ab)" = " 14 0 1 0 15 7 0 0" ]; } && ok "slot B started, the marker uc-pxx-slot-b-changed: no mark" || bad "marked B with its marker present (rc $rc)"

echo "== uc-pxx-arm-slot =="
reset; mksector 15,0,1 14,0,1
PATH="$T/bin:$PATH" sh "$T/ARM.sh" >/dev/null 2>&1; rc=$?
{ [ $rc = 0 ] && unchanged && [ -e "$T/run/uc-pxx-slot-a-changed" ]; } && ok "A successful becomes {15,7,0}, the marker exists" || bad "arm-slot failed (rc $rc)"
reset; mksector 15,0,1 14,3,0
PATH="$T/bin:$PATH" sh "$T/ARM.sh" >/dev/null 2>&1; rc=$?
{ [ $rc = 1 ] && [ "$(od -An -tu1 -j8 -N8 "$T/sector" | tr -s ' ')" = " 15 0 1 0 14 3 0 0" ]; } && ok "B not successful: refused, sector unchanged" || bad "arm-slot with B trying (rc $rc)"
grep -q '/run/uc-pxx-slot-a-changed' "$FLASH" && ok "the flash wrapper sets the same marker" || bad "the flash wrapper has another marker"
reset; mksector 15,0,1 14,0,1; ubootargs _b
PATH="$T/bin:$PATH" sh "$T/ARM.sh" >/dev/null 2>&1; rc=$?
{ [ $rc = 1 ] && [ "$(ab)" = " 15 0 1 0 14 0 1 0" ] && [ ! -e "$T/run/uc-pxx-slot-a-changed" ]; } && ok "the running system is slot B: refused before the lock and the marker, sector unchanged" || bad "arm-slot in slot B (rc $rc, $(ab))"
reset; mksector 15,0,1 14,0,1; rm -f "$T/ubootargs"
PATH="$T/bin:$PATH" sh "$T/ARM.sh" >/dev/null 2>&1; rc=$?
{ [ $rc = 0 ] && unchanged; } && ok "a RAM boot (no slot) arms as before" || bad "arm-slot without a slot (rc $rc)"
reset; mksector 15,0,1 14,0,1; ubootargs
PATH="$T/bin:$PATH" sh "$T/ARM.sh" >/dev/null 2>&1; rc=$?
{ [ $rc = 1 ] && [ "$(ab)" = " 15 0 1 0 14 0 1 0" ] && [ ! -e "$T/run/uc-pxx-slot-a-changed" ]; } && ok "u-boot,bootargs without a slot word (uc-pxx-slot exit 2): refused, sector unchanged" || bad "arm-slot with an unreadable slot (rc $rc, $(ab))"
reset; mksector 15,0,1 14,0,1; ubootargs _a _b
PATH="$T/bin:$PATH" sh "$T/ARM.sh" >/dev/null 2>&1; rc=$?
{ [ $rc = 1 ] && [ "$(ab)" = " 15 0 1 0 14 0 1 0" ]; } && ok "two slot words: refused, sector unchanged" || bad "arm-slot with two slot words (rc $rc, $(ab))"
reset; mksector 15,0,1 14,0,1; root 179:23
PATH="$T/bin:$PATH" sh "$T/ARM.sh" >/dev/null 2>&1; rc=$?
{ [ $rc = 1 ] && [ "$(ab)" = " 15 0 1 0 14 0 1 0" ] && [ ! -e "$T/run/uc-pxx-slot-a-changed" ]; } && ok "slot A started, but the root is system_b: refused, sector unchanged" || bad "arm-slot with the root on system_b (rc $rc, $(ab))"
reset; mksector 15,0,1 14,0,1; rm -f "$T/ubootargs"; root 179:23
PATH="$T/bin:$PATH" sh "$T/ARM.sh" >/dev/null 2>&1; rc=$?
{ [ $rc = 1 ] && [ "$(ab)" = " 15 0 1 0 14 0 1 0" ]; } && ok "a RAM boot whose root is not system_a: refused" || bad "arm-slot in a RAM boot on system_b (rc $rc, $(ab))"
reset; mksector 15,0,1 14,0,1; : > "$T/mountinfo"
PATH="$T/bin:$PATH" sh "$T/ARM.sh" >/dev/null 2>&1; rc=$?
{ [ $rc = 1 ] && [ "$(ab)" = " 15 0 1 0 14 0 1 0" ]; } && ok "no root line in mountinfo: refused" || bad "arm-slot without a root line (rc $rc, $(ab))"
reset; mksector 15,0,1 14,0,1; mv "$T/sys/block/mmcblk0p22/uevent" "$T/sys/block/mmcblk0p22/uevent.x"
PATH="$T/bin:$PATH" sh "$T/ARM.sh" >/dev/null 2>&1; rc=$?
mv "$T/sys/block/mmcblk0p22/uevent.x" "$T/sys/block/mmcblk0p22/uevent"
{ [ $rc = 1 ] && [ "$(ab)" = " 15 0 1 0 14 0 1 0" ]; } && ok "no partition named system_a: refused" || bad "arm-slot without system_a (rc $rc, $(ab))"
reset; mksector 15,0,1 14,0,1; rm -f "$T/bin/uc-pxx-slot.x"; mv "$T/bin/uc-pxx-slot" "$T/bin/uc-pxx-slot.x"
PATH="$T/bin:$PATH" sh "$T/ARM.sh" >/dev/null 2>&1; rc=$?
mv "$T/bin/uc-pxx-slot.x" "$T/bin/uc-pxx-slot"
{ [ $rc = 1 ] && [ "$(ab)" = " 15 0 1 0 14 0 1 0" ]; } && ok "no uc-pxx-slot program: refused" || bad "arm-slot without uc-pxx-slot (rc $rc, $(ab))"
# the flash wrapper: the same guard, before the lock, the marker, the arm and the dd
sed -n '/^# The slot-A guard/,/^	die "the running root file system/p' "$ARM" > "$T/guard-arm"
sed -n '/^# The slot-A guard/,/^	die "the running root file system/p' "$FLASH" > "$T/guard-flash"
{ [ -s "$T/guard-arm" ] && cmp -s "$T/guard-arm" "$T/guard-flash"; } && ok "the flash wrapper has the same slot-A guard as uc-pxx-arm-slot" || bad "the slot-A guards of the two programs differ"
gl=$(grep -n '^gs=$(/usr/sbin/uc-pxx-slot 2>/dev/null); grc=$?$' "$FLASH" | cut -d: -f1)
gl2=$(grep -n '^	die "the running root file system' "$FLASH" | cut -d: -f1)
fl=$(grep -n -m1 -e '^exec 9>' -e '^arm "' -e '^dd ' -e '^: > /run' -e '^grep -q "PARTNAME=boot_a"' "$FLASH" | cut -d: -f1)
{ [ -n "$gl" ] && [ -n "$gl2" ] && [ -n "$fl" ] && [ "$gl" -lt "$fl" ] && [ "$gl2" -lt "$fl" ]; } && ok "the flash wrapper refuses before it changes or reads anything" || bad "the flash wrapper's guard is missing or late ($gl, $gl2, $fl)"
reset; ( flock -n 9 && sleep 3 ) 9> "$T/run/uc-pxx-abdata.lock" & sleep 1
mksector 15,0,1 14,0,1
PATH="$T/bin:$PATH" sh "$T/ARM.sh" >/dev/null 2>&1; rc=$?; wait
{ [ $rc = 0 ] && unchanged; } && ok "arm-slot waits for the lock, then arms" || bad "arm-slot did not wait for the lock (rc $rc)"
echo "$N ok, $F failed"
[ "$F" = 0 ]
