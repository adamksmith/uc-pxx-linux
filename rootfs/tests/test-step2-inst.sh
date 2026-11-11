#!/bin/sh
# Host test for the build option UC_PXX_STEP2_BOOTCTL_INST of mkrootfs.sh
# (MAINLINE-STEP2-DESIGN Q-S8): uc-pxx-bootctl-inst r2 at one fixed path of the
# rootfs, root 0700, only when the option is given; off by default, and then
# no file of that name may be in the image. The step of mkrootfs.sh runs on a
# made-up tree; a stand-in binary takes the place of the pinned r2 (the pin
# itself is checked by text). Also the payload option --step2-bootctl-inst.
set -u
HERE=$(cd "$(dirname "$0")/.." && pwd)
MK=$HERE/mkrootfs.sh
BR=$HERE/build-rootfs.sh
PB=$HERE/../tools/mainline-payload/build.sh
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
N=0 F=0
ok()  { N=$((N + 1)); echo "  ok: $*"; }
bad() { F=$((F + 1)); echo "  FAIL: $*"; }
PIN=20aa6bc5d2146faace461eec0b50f741c681b3c58827788b9b806d9444b00203

echo "== the pins and the default =="
grep -q "^STEP2_INST_SHA256=$PIN\$" "$MK" && ok "mkrootfs.sh pins r2 $PIN" || bad "mkrootfs.sh: no pin of r2"
grep -q '^STEP2_INST_PATH=usr/libexec/uc-pxx-step2/uc-pxx-bootctl-inst$' "$MK" && ok "one fixed path" || bad "the path changed"
grep -q "^STEP2_INST_SHA=$PIN\$" "$PB" && ok "the payload build pins r2" || bad "the payload build: no pin of r2"
grep -q 'pin STEP2_BOOTCTL_INST_SHA256 none' "$PB" && ok "the payload build records none by default" || bad "no default none in the payload inputs"
grep -q 'in_file UC_PXX_STEP2_BOOTCTL_INST' "$BR" && ok "build-rootfs.sh passes the file only when it is set" || bad "build-rootfs.sh does not pass the option"
grep -q -- '-u UC_PXX_STEP2_BOOTCTL_INST' "$PB" && ok "the payload build clears the variable of the caller" || bad "the payload build keeps a stray UC_PXX_STEP2_BOOTCTL_INST"
grep -q -- '-u UC_PXX_STEP2_BIN' "$PB" && grep -q 'pin STEP2_BIN_SHA256 none' "$PB" && ok "the payload build clears UC_PXX_STEP2_BIN and records none by default" || bad "the payload build and UC_PXX_STEP2_BIN"

echo "== the step of mkrootfs.sh on a made-up tree =="
sed -n '/^# uc-pxx-bootctl-inst in the root file system/,/^log "manifest and sizes"$/p' "$MK" | sed '$d' > "$T/step.sh"
[ -s "$T/step.sh" ] && ok "the step is found" || bad "the step is not found"
printf '#!/bin/sh\necho stand-in r2\n' > "$T/inst"; chmod 755 "$T/inst"
printf '#!/bin/sh\necho stand-in uc-pxx-step2\n' > "$T/bin"; chmod 755 "$T/bin"
printf '#!/bin/sh\necho stand-in data tool\n' > "$T/data"
SUM=$(sha256sum "$T/inst" | cut -d' ' -f1) BSUM=$(sha256sum "$T/bin" | cut -d' ' -f1) DSUM=$(sha256sum "$T/data" | cut -d' ' -f1)
grep -q '^STEP2_BIN_SHA256=[0-9a-f]\{64\}$' "$MK" && ok "mkrootfs.sh pins uc-pxx-step2" || bad "no pin of uc-pxx-step2"
grep -q '^STEP2_DATA_SHA256=9162c65df08ac5577e38a2fe124d8cb1434b9b2bcfe787d6fba76055b8006791$' "$MK" && ok "the data tool of step 2 is pinned (9162c65d)" || bad "no pin of the data tool"
# the stand-ins take the place of the pins; ownership as the test user
sed -e "s/^STEP2_INST_SHA256=.*/STEP2_INST_SHA256=$SUM/" -e "s/^STEP2_BIN_SHA256=.*/STEP2_BIN_SHA256=$BSUM/" \
	-e "s/^STEP2_DATA_SHA256=.*/STEP2_DATA_SHA256=$DSUM/" -e 's/ -o 0 -g 0//g' "$T/step.sh" > "$T/step-t.sh"
step() { rm -rf "$T/R"; mkdir -p "$T/R/usr/sbin" "$T/R/etc"; cp "$T/data" "$T/R/usr/sbin/uc-pxx-data-migrate"; "$@"; ( log() { :; }; R=$T/R; . "$T/step-t.sh" ) > "$T/out" 2>&1; echo $?; }
rc=$(step true); [ "$rc" = 0 ] && [ ! -e "$T/R/usr/libexec/uc-pxx-step2" ] && ok "off (the default): nothing added" || bad "off: rc $rc"
rc=$(step touch "$T/R/usr/sbin/uc-pxx-bootctl-inst"); [ "$rc" != 0 ] && grep -q 'allows it in no slot' "$T/out" && ok "off, a package brought uc-pxx-bootctl-inst: the build stops" || bad "off with a stray file: rc $rc"
rc=$(step mkdir -p "$T/R/usr/libexec/uc-pxx-step2"); [ "$rc" != 0 ] && ok "off, a folder uc-pxx-step2 exists: the build stops" || bad "off with the folder: rc $rc"
rc=$(step sh -c "mkdir -p $T/R/etc/init.d; touch $T/R/etc/init.d/uc-pxx-step2"); [ "$rc" != 0 ] && grep -q 'files of step 2' "$T/out" && ok "off, a package brought an uc-pxx-step2 service: the build stops" || bad "off with a step-2 service: rc $rc"
export UC_PXX_STEP2_BIN=$T/bin
rc=$(step true); [ "$rc" != 0 ] && grep -q 'UC_PXX_STEP2_BIN needs UC_PXX_STEP2_BOOTCTL_INST' "$T/out" && ok "off, but UC_PXX_STEP2_BIN given: the build stops" || bad "off with UC_PXX_STEP2_BIN: rc $rc"
unset UC_PXX_STEP2_BIN
export UC_PXX_STEP2_BOOTCTL_INST=$T/inst
rc=$(step true); [ "$rc" != 0 ] && grep -q 'needs UC_PXX_STEP2_BIN' "$T/out" && ok "on without uc-pxx-step2: the build stops" || bad "on without the binary: rc $rc"
export UC_PXX_STEP2_BIN=$T/bin
rc=$(step rm -f "$T/R/usr/sbin/uc-pxx-data-migrate"); [ "$rc" != 0 ] && grep -q 'needs /usr/sbin/uc-pxx-data-migrate' "$T/out" && ok "on without the data tool: the build stops" || bad "on without the data tool: rc $rc"
rc=$(step true)
[ "$rc" = 0 ] && ok "on: the step passes" || bad "on: rc $rc ($(cat "$T/out"))"
[ "$(stat -c %a "$T/R/usr/libexec/uc-pxx-step2/uc-pxx-bootctl-inst" 2>/dev/null)" = 700 ] && ok "on: the binary is mode 0700" || bad "on: mode of the binary"
[ "$(stat -c %a "$T/R/usr/libexec/uc-pxx-step2" 2>/dev/null)" = 700 ] && ok "on: the folder is mode 0700" || bad "on: mode of the folder"
cmp -s "$T/inst" "$T/R/usr/libexec/uc-pxx-step2/uc-pxx-bootctl-inst" && ok "on: the same bytes" || bad "on: the bytes differ"
grep -q 'For no unit before its RULES line' "$T/R/etc/tsx/step2-bootctl-inst" && ok "on: the image says it is a step-2 build" || bad "on: no marker file"
[ "$(stat -c %a "$T/R/usr/libexec/uc-pxx-step2/uc-pxx-step2" 2>/dev/null)" = 700 ] && cmp -s "$T/bin" "$T/R/usr/libexec/uc-pxx-step2/uc-pxx-step2" && ok "on: uc-pxx-step2, 0700, the same bytes" || bad "on: uc-pxx-step2"
cmp -s "$HERE/step2/init.d/uc-pxx-step2" "$T/R/etc/init.d/uc-pxx-step2" && [ "$(stat -c %a "$T/R/etc/init.d/uc-pxx-step2")" = 755 ] && ok "on: the service script" || bad "on: the service script"
[ "$(readlink "$T/R/etc/runlevels/default/uc-pxx-step2")" = /etc/init.d/uc-pxx-step2 ] && ok "on: the service in the default runlevel" || bad "on: not in the default runlevel"
grep -qx 'UC_PXX_STEP2_PAYLOAD=' "$T/R/etc/conf.d/uc-pxx-step2" && ok "on: the conf file names no payload (the service asks nothing)" || bad "on: the conf file"
[ -s "$T/R/etc/uc-pxx-step2/supervised" ] && ok "on: the supervised marker" || bad "on: no supervised marker"
rc=$(step touch "$T/R/usr/sbin/uc-pxx-bootctl-inst"); [ "$rc" != 0 ] && grep -q 'only /usr/libexec' "$T/out" && ok "on, a second copy elsewhere: the build stops" || bad "on with a second copy: rc $rc"
rc=$(step sh -c "mkdir -p $T/R/usr/local/sbin; touch $T/R/usr/local/sbin/uc-pxx-step2-extra"); [ "$rc" != 0 ] && grep -q 'uc-pxx-step2 files in the image' "$T/out" && ok "on, a stray uc-pxx-step2 file: the build stops" || bad "on with a stray step-2 file: rc $rc"
printf 'other\n' > "$T/other"; export UC_PXX_STEP2_BIN=$T/other
rc=$(step true); [ "$rc" != 0 ] && grep -q 'the pinned uc-pxx-step2 is' "$T/out" && ok "on, another uc-pxx-step2: the build stops" || bad "on with another uc-pxx-step2: rc $rc"
export UC_PXX_STEP2_BIN=$T/bin UC_PXX_STEP2_BOOTCTL_INST=$T/other
rc=$(step true); [ "$rc" != 0 ] && grep -q 'the reviewed r2 binary is' "$T/out" && ok "on, another binary: the build stops" || bad "on with another binary: rc $rc"
unset UC_PXX_STEP2_BOOTCTL_INST UC_PXX_STEP2_BIN

echo "== the fstab step of mkrootfs.sh (an older uc-pxx-lvm, review R1-1) =="
sed -n '/^# The fstab of this repository has no \/data line/,/^# (end of the fstab step)$/p' "$MK" > "$T/fstab-step.sh"
[ -s "$T/fstab-step.sh" ] && ok "the fstab step is found" || bad "the fstab step is not found"
fstep() { rm -rf "$T/R"; mkdir -p "$T/R/etc/init.d"; cp "$HERE/overlay/etc/fstab" "$T/R/etc/fstab"; "$@"; ( log() { :; }; R=$T/R; . "$T/fstab-step.sh" ) > /dev/null 2>&1; grep -v '^#' "$T/R/etc/fstab" | awk '$2 == "/data" { print $1 }'; }
[ "$(fstep cp "$HERE/overlay/etc/init.d/uc-pxx-lvm" "$T/R/etc/init.d/")" = "" ] && ok "the uc-pxx-lvm of this repository: no /data line" || bad "a /data line with the new service"
[ "$(fstep sh -c "printf '#!/sbin/openrc-run\nstart() { :; }\n' > $T/R/etc/init.d/uc-pxx-lvm")" = "LABEL=tsxdata" ] && ok "an older uc-pxx-lvm (no marker): the old /data line comes back" || bad "no compat line for an older service"
[ "$(fstep true)" = "" ] && ok "no uc-pxx-lvm at all: no /data line" || bad "a /data line without the service"

echo "$N ok, $F failed"
[ "$F" = 0 ]
