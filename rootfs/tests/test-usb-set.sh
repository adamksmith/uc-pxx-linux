#!/bin/sh
# Host test for the USB set of mkrootfs.sh (UC_PXX_XFER_BIN; uc-pxx-installer
# mainline-rc-4, docs/usb.md): the WebUSB interface of every both-slot build.
# The step of mkrootfs.sh runs on a made-up tree; a stand-in binary takes the
# place of the pinned uc-pxx-xfer (the pin itself is checked by text). Also the
# files of rootfs/usb/ and the payload option --xfer-bin.
set -u
HERE=$(cd "$(dirname "$0")/.." && pwd)
MK=$HERE/mkrootfs.sh BR=$HERE/build-rootfs.sh PB=$HERE/../tools/mainline-payload/build.sh U=$HERE/usb
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
N=0 F=0
ok()  { N=$((N + 1)); echo "  ok: $*"; }
bad() { F=$((F + 1)); echo "  FAIL: $*"; }

echo "== the pins and the files =="
grep -q '^XFER_SHA256=[0-9a-f]\{64\}$' "$MK" && ok "mkrootfs.sh pins uc-pxx-xfer" || bad "no pin of uc-pxx-xfer"
grep -q '^XFER_PATH=usr/libexec/uc-pxx-xfer/uc-pxx-xfer$' "$MK" && ok "one fixed path" || bad "the path changed"
grep -q 'in_file UC_PXX_XFER_BIN' "$BR" && ok "build-rootfs.sh passes the file only when it is set" || bad "build-rootfs.sh"
grep -q -- '-u UC_PXX_XFER_BIN' "$PB" && grep -q 'pin XFER_BIN_SHA256 none' "$PB" && ok "the payload build clears the variable and records none by default" || bad "the payload build"
grep -q -- '--require-both-slot needs --xfer-bin' "$PB" && ok "a both-slot payload needs the USB set" || bad "--require-both-slot without --xfer-bin"
grep -qx 'UC_PXX_USB_NET=off' "$U/conf.d/uc-pxx-usb" && ok "the USB network is off by default" || bad "the USB network default"
[ "$(grep -v '^#' "$U/conf.d/uc-pxx-usb" | grep -c .)" = 1 ] && ok "the conf file sets nothing else" || bad "the conf file sets more"
grep -q 'command_args="usb"' "$U/init.d/uc-pxx-usb" && grep -q 'on) command_args="usb --net"' "$U/init.d/uc-pxx-usb" && ok "--net only with UC_PXX_USB_NET=on" || bad "the init script and --net"
! grep -qi 'acm\|ttyGS\|mass_storage' "$U/init.d/uc-pxx-usb" && ok "the service makes no serial or storage function" || bad "a serial/storage function in the service"
python3 - "$U/finish.json" <<'EOP' && ok "finish.json: uc-pxx-step2-finish then r2 20aa6bc5 777976" || bad "finish.json"
import json, sys, re
l = json.load(open(sys.argv[1]))
assert set(l) == {"kind", "version", "files"} and l["kind"] == "uc-pxx-finish" and l["version"] == 1
f = l["files"]
assert [x["name"] for x in f] == ["uc-pxx-step2-finish", "uc-pxx-bootctl-inst"]
assert all(set(x) == {"name", "size", "sha256"} and re.fullmatch("[0-9a-f]{64}", x["sha256"]) and 0 < x["size"] <= 32 << 20 for x in f)
assert f[1] == {"name": "uc-pxx-bootctl-inst", "size": 777976, "sha256": "20aa6bc5d2146faace461eec0b50f741c681b3c58827788b9b806d9444b00203"}
EOP
grep -q "^Match LocalAddress 10.99.0.2$" "$U/sshd_config.d/uc-pxx-usb.conf" && grep -q "^Match Address 10.99.0.0/24$" "$U/sshd_config.d/uc-pxx-usb.conf" && grep -q 'PasswordAuthentication no' "$U/sshd_config.d/uc-pxx-usb.conf" &&
	grep -q 'AuthenticationMethods publickey' "$U/sshd_config.d/uc-pxx-usb.conf" && ok "ssh by key only on 10.99.0.2" || bad "the sshd drop-in"

echo "== the step of mkrootfs.sh on a made-up tree =="
sed -n '/^# The USB set (uc-pxx-installer mainline-rc-4/,/^# uc-pxx-bootctl-inst in the root file system/p' "$MK" | sed '$d' > "$T/step.sh"
[ -s "$T/step.sh" ] && ok "the step is found" || bad "the step is not found"
printf '#!/bin/sh\necho stand-in uc-pxx-xfer\n' > "$T/xfer"; chmod 755 "$T/xfer"
SUM=$(sha256sum "$T/xfer" | cut -d' ' -f1)
sed -e "s/^XFER_SHA256=.*/XFER_SHA256=$SUM/" -e 's/ -o 0 -g 0//g' "$T/step.sh" > "$T/step-t.sh"
mktree() {
	rm -rf "$T/R"; mkdir -p "$T/R/etc/init.d" "$T/R/etc/conf.d" "$T/R/etc/runlevels/default" "$T/R/etc/ssh"
	printf '#!/sbin/openrc-run\n# uc-pxx-data-mount: 1\n' > "$T/R/etc/init.d/uc-pxx-lvm"
	printf 'root:x:0:0:root:/root:/bin/sh\nnobody:x:65534:65534:nobody:/:/sbin/nologin\n' > "$T/R/etc/passwd"
	printf 'root:x:0:root\nnogroup:x:65533:\n' > "$T/R/etc/group"; printf 'root:*::0:::::\n' > "$T/R/etc/shadow"
	printf 'Include /etc/ssh/sshd_config.d/*.conf\nPermitRootLogin yes\n' > "$T/R/etc/ssh/sshd_config"
	printf '::sysinit:/sbin/openrc sysinit\nttyS2::respawn:/sbin/getty -L 115200 ttyS2 vt100\n' > "$T/R/etc/inittab"
}
step() { mktree; "$@"; ( log() { :; }; HERE=$HERE; R=$T/R; . "$T/step-t.sh" ) > "$T/out" 2>&1; echo $?; }
rc=$(step true); [ "$rc" = 0 ] && [ ! -e "$T/R/usr/libexec/uc-pxx-xfer" ] && ! grep -q uc-pxx-xfer "$T/R/etc/passwd" && ok "off: nothing added" || bad "off: rc $rc"
rc=$(step sh -c "mkdir -p $T/R/usr/bin; touch $T/R/usr/bin/uc-pxx-xfer"); [ "$rc" != 0 ] && grep -q 'without UC_PXX_XFER_BIN' "$T/out" && ok "off, a stray uc-pxx-xfer: the build stops" || bad "off with a stray file: rc $rc"
rc=$(step sh -c "printf 'ttyGS0::respawn:/sbin/getty ttyGS0\n' >> $T/R/etc/inittab"); [ "$rc" != 0 ] && grep -q 'ttyGS' "$T/out" && ok "a getty on ttyGS0: the build stops" || bad "ttyGS getty: rc $rc"
export UC_PXX_XFER_BIN=$T/xfer
rc=$(step true); [ "$rc" = 0 ] && ok "on: the step passes" || bad "on: rc $rc ($(cat "$T/out"))"
[ "$(stat -c %a "$T/R/usr/libexec/uc-pxx-xfer/uc-pxx-xfer")" = 755 ] && [ "$(stat -c %a "$T/R/usr/libexec/uc-pxx-xfer")" = 755 ] && cmp -s "$T/xfer" "$T/R/usr/libexec/uc-pxx-xfer/uc-pxx-xfer" && ok "on: the binary 0755 in a 0755 folder (the receiver's user runs it: review F2)" || bad "on: the binary"
cmp -s "$U/init.d/uc-pxx-usb" "$T/R/etc/init.d/uc-pxx-usb" && cmp -s "$U/conf.d/uc-pxx-usb" "$T/R/etc/conf.d/uc-pxx-usb" && cmp -s "$U/finish.json" "$T/R/usr/share/uc-pxx-usb/finish.json" &&
	cmp -s "$U/sshd_config.d/uc-pxx-usb.conf" "$T/R/etc/ssh/sshd_config.d/uc-pxx-usb.conf" && ok "on: the four files, byte for byte" || bad "on: the files"
[ "$(stat -c %a "$T/R/usr/share/uc-pxx-usb/finish.json")" = 644 ] && ok "on: finish.json 0644" || bad "on: finish.json mode"
[ "$(readlink "$T/R/etc/runlevels/default/uc-pxx-usb")" = /etc/init.d/uc-pxx-usb ] && ok "on: the service in the default runlevel" || bad "on: the runlevel"
grep -qx 'uc-pxx-xfer:x:990:990:uc-pxx USB receiver:/nonexistent:/sbin/nologin' "$T/R/etc/passwd" && grep -qx 'uc-pxx-xfer:x:990:' "$T/R/etc/group" &&
	grep -qx 'uc-pxx-xfer:!:::::::' "$T/R/etc/shadow" && ok "on: the user and group 990, own group, no member, no login" || bad "on: the user"
rc=$(step sh -c "echo 'other:x:990:990::/:/bin/sh' >> $T/R/etc/passwd"); [ "$rc" != 0 ] && grep -q 'is taken' "$T/out" && ok "on, uid 990 taken: the build stops" || bad "on with uid 990 taken: rc $rc"
rc=$(step sh -c "echo '# no marker' > $T/R/etc/init.d/uc-pxx-lvm"); [ "$rc" != 0 ] && grep -q 'both-slot image only' "$T/out" && ok "on, not a both-slot image: the build stops" || bad "on, slot-A shape: rc $rc"
rc=$(step sh -c "echo 'PermitRootLogin yes' > $T/R/etc/ssh/sshd_config"); [ "$rc" != 0 ] && grep -q 'does not include sshd_config.d' "$T/out" && ok "on, sshd_config without the Include: the build stops" || bad "on without Include: rc $rc"
rc=$(step sh -c "mkdir -p $T/R/usr/local/bin; touch $T/R/usr/local/bin/uc-pxx-usb-helper"); [ "$rc" != 0 ] && grep -q 'not exactly' "$T/out" && ok "on, a stray uc-pxx-usb file: the build stops" || bad "on with a stray file: rc $rc"
printf 'other\n' > "$T/other"; export UC_PXX_XFER_BIN=$T/other
rc=$(step true); [ "$rc" != 0 ] && grep -q 'the pinned uc-pxx-xfer is' "$T/out" && ok "on, another uc-pxx-xfer: the build stops" || bad "on with another binary: rc $rc"
unset UC_PXX_XFER_BIN

echo "$N ok, $F failed"
[ "$F" = 0 ]
