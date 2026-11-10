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

echo "== the step of mkrootfs.sh on a made-up tree =="
sed -n '/^# uc-pxx-bootctl-inst in the root file system/,/^log "manifest and sizes"$/p' "$MK" | sed '$d' > "$T/step.sh"
[ -s "$T/step.sh" ] && ok "the step is found" || bad "the step is not found"
printf '#!/bin/sh\necho stand-in r2\n' > "$T/inst"; chmod 755 "$T/inst"
SUM=$(sha256sum "$T/inst" | cut -d' ' -f1)
# the stand-in takes the place of the pin; ownership as the test user
sed -e "s/^STEP2_INST_SHA256=.*/STEP2_INST_SHA256=$SUM/" -e 's/ -o 0 -g 0//g' "$T/step.sh" > "$T/step-t.sh"
step() { rm -rf "$T/R"; mkdir -p "$T/R/usr/sbin" "$T/R/etc"; "$@"; ( log() { :; }; R=$T/R; . "$T/step-t.sh" ) > "$T/out" 2>&1; echo $?; }
rc=$(step true); [ "$rc" = 0 ] && [ ! -e "$T/R/usr/libexec/uc-pxx-step2" ] && ok "off (the default): nothing added" || bad "off: rc $rc"
rc=$(step touch "$T/R/usr/sbin/uc-pxx-bootctl-inst"); [ "$rc" != 0 ] && grep -q 'allows it in no slot' "$T/out" && ok "off, a package brought uc-pxx-bootctl-inst: the build stops" || bad "off with a stray file: rc $rc"
rc=$(step mkdir -p "$T/R/usr/libexec/uc-pxx-step2"); [ "$rc" != 0 ] && ok "off, a folder uc-pxx-step2 exists: the build stops" || bad "off with the folder: rc $rc"
export UC_PXX_STEP2_BOOTCTL_INST=$T/inst
rc=$(step true)
[ "$rc" = 0 ] && ok "on: the step passes" || bad "on: rc $rc ($(cat "$T/out"))"
[ "$(stat -c %a "$T/R/usr/libexec/uc-pxx-step2/uc-pxx-bootctl-inst" 2>/dev/null)" = 700 ] && ok "on: the binary is mode 0700" || bad "on: mode of the binary"
[ "$(stat -c %a "$T/R/usr/libexec/uc-pxx-step2" 2>/dev/null)" = 700 ] && ok "on: the folder is mode 0700" || bad "on: mode of the folder"
cmp -s "$T/inst" "$T/R/usr/libexec/uc-pxx-step2/uc-pxx-bootctl-inst" && ok "on: the same bytes" || bad "on: the bytes differ"
grep -q 'For no unit before its RULES line' "$T/R/etc/tsx/step2-bootctl-inst" && ok "on: the image says it is a step-2 build" || bad "on: no marker file"
rc=$(step touch "$T/R/usr/sbin/uc-pxx-bootctl-inst"); [ "$rc" != 0 ] && grep -q 'only /usr/libexec' "$T/out" && ok "on, a second copy elsewhere: the build stops" || bad "on with a second copy: rc $rc"
printf 'other\n' > "$T/other"; export UC_PXX_STEP2_BOOTCTL_INST=$T/other
rc=$(step true); [ "$rc" != 0 ] && grep -q 'the reviewed r2 binary is' "$T/out" && ok "on, another binary: the build stops" || bad "on with another binary: rc $rc"
unset UC_PXX_STEP2_BOOTCTL_INST

echo "$N ok, $F failed"
[ "$F" = 0 ]
