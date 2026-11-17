#!/bin/sh
# Host test of the install screen of an R23 base (rootfs/install-screen/):
#   - state: installing only on a slot with the step-2 and provisioning sets,
#     until "never", "done" or an "armed" line of step 2
#   - tty1: while installing, the large font and the screen text on tty1, no
#     getty; then the getty (also at once on a slot that is not installing)
#   - bigfont.py: a PSF1 8x16 font becomes a PSF2 16x32 font, each pixel 2x2
#   - the service: the kiosk URL file only while installing, and its watcher
#     removes it (and restarts a running kiosk) when the install has ended
#   - the console inittab runs the tty1 program when it is there, else getty
set -u
HERE=$(cd "$(dirname "$0")/.." && pwd)
D=$HERE/install-screen
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
N=0 F=0
ok()  { N=$((N + 1)); echo "  ok: $*"; }
bad() { F=$((F + 1)); echo "  FAIL: $*"; }
eq() { if [ "$1" = "$2" ]; then ok "$3"; else bad "$3 (got '$1', want '$2')"; fi; }

echo "== syntax and modes =="
for f in state tty1 uc-pxx-install-screen.init; do
	busybox sh -n "$D/$f" && ok "$f passes busybox sh -n" || bad "$f: busybox sh -n"
	[ -x "$D/$f" ] && ok "$f is executable" || bad "$f is not executable"
done
head -n 1 "$D/uc-pxx-install-screen.init" | grep -qx '#!/sbin/openrc-run' && ok "the service is an OpenRC script" || bad "no openrc-run line"
grep -Eq 'dd |mmcblk|of=|uc-pxx-bootctl|/dev/sd' "$D/state" "$D/tty1" "$D/uc-pxx-install-screen.init" && bad "the install screen names a block device or a boot tool" || ok "no block device and no boot tool in the install screen"

echo "== state =="
R=$T/root
st() { UC_PXX_INSTALL_ROOT=$R sh "$D/state"; }
mkdir -p "$R/usr/libexec/uc-pxx-step2" "$R/etc/init.d" "$R/var/lib/uc-pxx-step2"
eq "$(st)" "no" "no step-2 set: not installing"
printf '#!/bin/sh\n' > "$R/usr/libexec/uc-pxx-step2/uc-pxx-step2"; chmod 700 "$R/usr/libexec/uc-pxx-step2/uc-pxx-step2"
eq "$(st)" "no" "the step-2 set without the provisioning service: not installing"
: > "$R/etc/init.d/uc-pxx-provision"
eq "$(st)" "installing" "an R23 base slot before step 2: installing"
st > /dev/null; eq "$?" 0 "installing: exit 0"
echo "started 1234" > "$R/var/lib/uc-pxx-step2/state"
eq "$(st)" "installing" "step 2 started (no armed line): installing"
echo "armed 1234" >> "$R/var/lib/uc-pxx-step2/state"
eq "$(st)" "no" "step 2 armed slot A: not installing (this slot is the fallback now)"
st > /dev/null; eq "$?" 1 "not installing: exit 1"
echo "started 1234" > "$R/var/lib/uc-pxx-step2/state"; : > "$R/var/lib/uc-pxx-step2/never"
eq "$(st)" "no" "never (do not ask again): not installing"
rm "$R/var/lib/uc-pxx-step2/never"; : > "$R/var/lib/uc-pxx-step2/done"
eq "$(st)" "no" "done: not installing"
rm "$R/var/lib/uc-pxx-step2/done"
# slot A after the clone: step 2's difference removes the two sets
mv "$R/usr/libexec/uc-pxx-step2" "$T/s2.away"
eq "$(st)" "no" "slot A (the clone, no step-2 set): not installing"
mv "$T/s2.away" "$R/usr/libexec/uc-pxx-step2"

echo "== bigfont.py =="
python3 - "$T/f16.psf" <<'PY'
import sys
glyphs = bytearray()
for g in range(256):
    glyphs += bytes((g if y == 3 else (0x81 if y == 8 else 0)) for y in range(16))
open(sys.argv[1], "wb").write(b"\x36\x04\x00\x10" + glyphs)
PY
python3 -I -B "$D/bigfont.py" "$T/f16.psf" "$T/f32.psf" && ok "bigfont.py runs" || bad "bigfont.py failed"
python3 - "$T/f32.psf" > "$T/fcheck" <<'PY'
import struct, sys
b = open(sys.argv[1], "rb").read()
m, v, hs, fl, n, sz, h, w = struct.unpack("<8I", b[:32])
print(hex(m), n, sz, h, w, len(b))
g = b[32 + sz * 0x5a:32 + sz * 0x5b]          # glyph 0x5a: row 3 = 01011010, row 8 = 10000001
print(g[12:14].hex(), g[14:16].hex(), g[32:34].hex(), g[34:36].hex(), g[0:2].hex())
PY
eq "$(sed -n 1p "$T/fcheck")" "0x864ab572 256 64 32 16 16416" "a PSF2 font of 256 glyphs, 16x32, 64 bytes each"
eq "$(sed -n 2p "$T/fcheck")" "33cc 33cc c003 c003 0000" "each pixel is doubled in width and in height"

echo "== tty1 =="
mkdir -p "$T/bin" "$T/lib/is" "$T/run"
cp "$D"/* "$T/lib/is/"
printf '#!/bin/sh\necho "setfont $*" >> "%s/setfont.log"; exit 0\n' "$T" > "$T/bin/setfont"; chmod 755 "$T/bin/setfont"
printf '#!/bin/sh\necho "UC_PXX_INSTALL_ROOT=%s exec %s/state" > /dev/null\nUC_PXX_INSTALL_ROOT=%s exec sh %s/state\n' "$R" "$D" "$R" "$D" > "$T/lib/is/state"; chmod 755 "$T/lib/is/state"
tt() { env UC_PXX_INSTALL_SCREEN_DIR="$T/lib/is" UC_PXX_INSTALL_RUN="$T/run" UC_PXX_TTY="$T/tty" UC_PXX_SETFONT="$T/bin/setfont" \
	UC_PXX_GETTY="echo getty-ran" UC_PXX_POLL=0.2 sh "$D/tty1"; }
: > "$T/tty"; rm -f "$T/setfont.log"
( sleep 1; echo "armed 9" >> "$R/var/lib/uc-pxx-step2/state" ) &
out=$(tt); wait
eq "$out" "getty-ran" "installing: the getty runs once the install has ended (armed)"
grep -q 'Installing the system on this unit' "$T/tty" && ok "the screen text is on tty1" || bad "no screen text on tty1"
grep -q "setfont -C $T/tty $T/run/font-32.psf" "$T/setfont.log" 2>/dev/null && ok "the 16x32 font is set on tty1" || bad "no setfont of the large font: $(cat "$T/setfont.log" 2>/dev/null)"
: > "$T/tty"; rm -f "$T/setfont.log"
out=$(tt)
eq "$out" "getty-ran" "not installing: the getty at once"
[ ! -s "$T/tty" ] && [ ! -e "$T/setfont.log" ] && ok "not installing: no text and no font change" || bad "not installing: the screen was changed"

echo "== the console inittab =="
IT=$HERE/profiles/console/overlay/etc/inittab
grep -qx 'tty1::respawn:/bin/sh -c "\[ -x /usr/libexec/uc-pxx-install-screen/tty1 \] && exec /usr/libexec/uc-pxx-install-screen/tty1 || exec /sbin/getty 38400 tty1"' "$IT" &&
	ok "tty1: the install-screen program when it is there, else getty" || bad "the tty1 line of the console inittab"
line=$(sed -n 's/^tty1::respawn:\/bin\/sh -c "\(.*\)"$/\1/p' "$IT" | sed "s#/usr/libexec/uc-pxx-install-screen/tty1#$T/none#g; s#exec /sbin/getty 38400 tty1#echo getty#")
eq "$(sh -c "$line")" "getty" "without the program (every image but an R23 base): getty"

echo "== the service =="
SV=$T/sv; mkdir -p "$SV/run/tsx"
sed -e "s#^D=/usr/libexec/uc-pxx-install-screen#D=$T/lib/is#" -e "s#^RUN=/run/uc-pxx-install-screen#RUN=$SV/run/is#" \
	-e "s#^URLF=/run/tsx/kiosk-url#URLF=$SV/run/tsx/kiosk-url#" -e 's#sleep 10#sleep 0.2#' -e "s#rc-service#$T/bin/rc-service#g" \
	"$D/uc-pxx-install-screen.init" > "$SV/init"
printf '#!/bin/sh\necho "rc-service $*" >> "%s/rc.log"; exit 0\n' "$T" > "$T/bin/rc-service"; chmod 755 "$T/bin/rc-service"
printf '#!/bin/sh\nexec "$@"\n' > "$T/bin/setsid"; chmod 755 "$T/bin/setsid"
svc() { ( ebegin() { :; }; eend() { return "${1:-0}"; }; checkpath() { while [ $# -gt 0 ]; do case $1 in -*) shift 2;; *) mkdir -p "$1"; shift;; esac; done; }
	PATH="$T/bin:$PATH"; . "$SV/init"; start ); }
echo "started 7" > "$R/var/lib/uc-pxx-step2/state"; rm -f "$T/rc.log"
svc
eq "$(cat "$SV/run/tsx/kiosk-url" 2>/dev/null)" "file://$SV/run/is/screen.html" "installing: the kiosk URL file names the install page"
cmp -s "$SV/run/is/screen.html" "$D/screen.html" && ok "the install page is in /run" || bad "no install page in /run"
grep -q 'setup' "$D/screen.html" && bad "the install page mentions the setup" || ok "the install page is not the setup page"
: > "$R/var/lib/uc-pxx-step2/never"; sleep 1.2
[ ! -e "$SV/run/tsx/kiosk-url" ] && ok "the install ended (never): the watcher removed the URL file" || bad "the URL file stays after the end"
grep -q 'rc-service kiosk restart' "$T/rc.log" 2>/dev/null && ok "and restarted the running kiosk" || bad "no kiosk restart: $(cat "$T/rc.log" 2>/dev/null)"
rm -rf "$SV/run"; mkdir -p "$SV/run/tsx"
svc
[ ! -e "$SV/run/tsx/kiosk-url" ] && [ ! -d "$SV/run/is" ] && ok "not installing: the service writes nothing" || bad "not installing: files written"
rm -f "$R/var/lib/uc-pxx-step2/never"; rm -rf "$SV/run"; mkdir -p "$SV/run/tsx"; rm -f "$T/rc.log"
svc; echo "https://other.example/" > "$SV/run/tsx/kiosk-url"
: > "$R/var/lib/uc-pxx-step2/never"; sleep 1.2
eq "$(cat "$SV/run/tsx/kiosk-url" 2>/dev/null)" "https://other.example/" "the watcher leaves a URL file that another program wrote"
[ ! -e "$T/rc.log" ] && ok "and does not restart the kiosk then" || bad "kiosk restarted for a foreign URL"
echo "$N passed, $F failed"
[ "$F" = 0 ]
