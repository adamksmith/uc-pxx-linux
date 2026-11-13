#!/bin/sh
# Host test for the SSH plugin of the end-user build (rootfs/ssh/uc_pxx_ssh.sh,
# docs/mainline-payload.md "SSH access"). It runs tsx-config of
# tsx-linux-common (TSX_COMMON, default ../tsx-linux-common next to this
# repository) with the plugin in a test plugin folder, a test panel.conf and a
# test root (TSX_APPLY_PREFIX). Stand-ins for rc-update and rc-service record
# what the plugin asks for. It checks:
#   - with no key, apply turns nothing on
#   - the setup page's key (tsx-config set SSH_AUTHORIZED_KEY) turns sshd on:
#     at boot (the boot runlevel) only the runlevel link, after the boot also
#     the start
#   - a key line in /root/.ssh/authorized_keys alone turns it on, a link does not
#   - a key that tsx-config refuses turns nothing on
#   - SSH_SERVER=off turns sshd off (the link and the service), also with a key
#   - SSH_SERVER takes only auto, off or empty
# Without the checkout the test prints SKIPPED. It writes no file into it.
set -u
HERE=$(cd "$(dirname "$0")/.." && pwd)
PLUGIN=$HERE/ssh/uc_pxx_ssh.sh
COMMON=${TSX_COMMON:-$HERE/../../tsx-linux-common}
CFG=$COMMON/base/usr/local/sbin/tsx-config
[ -f "$CFG" ] || { echo "SKIPPED: no tsx-linux-common (set TSX_COMMON)"; exit 0; }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fails=0
ok() { echo "ok   $*"; }
bad() { echo "FAIL $*"; fails=$((fails + 1)); }

# the plugin folder: the file with the modes of the image (root-owned there;
# here the test user, TSX_PLUGIN_OWNER_UID)
mkdir -p "$T/pd" "$T/bin"; cp "$PLUGIN" "$T/pd/uc_pxx_ssh.sh"; chmod 755 "$T/pd"; chmod 644 "$T/pd/uc_pxx_ssh.sh"
cat > "$T/bin/rc-update" <<SH
#!/bin/sh
echo "rc-update \$*" >> "$T/calls"
case "\$1 \$2 \$3" in
"add sshd default") mkdir -p "$T/root/etc/runlevels/default"; ln -sf /etc/init.d/sshd "$T/root/etc/runlevels/default/sshd";;
"del sshd default") rm -f "$T/root/etc/runlevels/default/sshd";;
*) exit 1;;
esac
SH
cat > "$T/bin/rc-service" <<SH
#!/bin/sh
echo "rc-service \$*" >> "$T/calls"
[ "\$1" = sshd ] || exit 1
case "\$2" in
status) [ -e "$T/sshd.started" ];;
start) : > "$T/sshd.started";;
stop) rm -f "$T/sshd.started";;
*) exit 1;;
esac
SH
chmod 755 "$T/bin/rc-update" "$T/bin/rc-service"
KEY="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIM0dE1cT7test0nly0key0for0the0plugin0test0x9 test@host"

reset() {
	rm -rf "$T/root" "$T/run" "$T/state" "$T/conf" "$T/calls" "$T/sshd.started"
	mkdir -p "$T/root/etc/init.d" "$T/root/root" "$T/run" "$T/state" "$T/conf"
	: > "$T/root/etc/init.d/sshd"
	printf 'root:*:19000:0:::::\n' > "$T/root/etc/shadow"
	: > "$T/conf/panel.conf"; chmod 600 "$T/conf/panel.conf"
	: > "$T/calls"
	echo boot > "$T/softlevel"
}
cfg() {
	env TSX_CONF="$T/conf/panel.conf" TSX_RUN="$T/run" TSX_STATE_DIR="$T/state" TSX_APPLY_PREFIX="$T/root" \
		TSX_CONF_SEED="$T/none.seed" TSX_HW_CONF="$T/none.hw" TSX_APPLY_ALLOW_NONROOT=1 \
		TSX_CONFIG_PLUGIN_DIR="$T/pd" TSX_PLUGIN_OWNER_UID="$(id -u)" TSX_BOARD_CONF="$HERE/overlay/usr/local/lib/tsx/board.sh" \
		UC_PXX_SSH_RC_UPDATE="$T/bin/rc-update" UC_PXX_SSH_RC_SERVICE="$T/bin/rc-service" UC_PXX_SSH_SOFTLEVEL="$T/softlevel" \
		PATH="/usr/bin:/bin" sh "$CFG" "$@"
}
link() { [ -L "$T/root/etc/runlevels/default/sshd" ]; }
started() { [ -e "$T/sshd.started" ]; }

echo "== the plugin loads"
reset
cfg apply > "$T/out" 2>&1
if grep -q 'plugin.*uc_pxx_ssh.*skipped\|no plugin loaded' "$T/out" || ! grep -q 'apply done' "$T/out"; then
	bad "the plugin did not load or apply failed: $(cat "$T/out")"
else
	ok "the plugin loads, apply runs to the end"
fi
cfg validate SSH_SERVER off > /dev/null 2>&1 && ok "tsx-config knows the key SSH_SERVER of the plugin" || bad "tsx-config does not know SSH_SERVER"

echo "== no key: nothing turns on"
reset; echo default > "$T/softlevel"
cfg apply > "$T/out" 2>&1
{ ! link && ! started && ! grep -q 'rc-update add\|sshd start' "$T/calls"; } && ok "no key: no link, no start" || bad "no key: $(cat "$T/calls")"

echo "== the setup page's key, at boot (boot runlevel) and after the boot"
reset
cfg set SSH_AUTHORIZED_KEY "$KEY" > "$T/out" 2>&1 && ok "tsx-config set takes the key" || bad "set: $(cat "$T/out")"
cfg apply > "$T/out" 2>&1
{ link && ! started && grep -qxF "$KEY" "$T/root/root/.ssh/authorized_keys"; } && ok "at boot: the link, no start yet, the key in authorized_keys" || bad "at boot: link=$(link && echo y) started=$(started && echo y) $(cat "$T/calls") $(cat "$T/out")"
echo default > "$T/softlevel"
cfg apply > "$T/out" 2>&1
{ link && started && grep -q 'rc-service sshd start' "$T/calls"; } && ok "after the boot: sshd started" || bad "after the boot: $(cat "$T/calls")"
: > "$T/calls"; cfg apply > "$T/out" 2>&1
{ link && started && ! grep -q 'rc-update add\|sshd start\|sshd stop\|rc-update del' "$T/calls"; } && ok "again: no change" || bad "again: $(cat "$T/calls")"

echo "== the save of the setup page at runtime (default runlevel, sshd stopped, no link)"
reset; echo default > "$T/softlevel"
cfg set SSH_AUTHORIZED_KEY "$KEY" > /dev/null 2>&1
cfg apply > "$T/out" 2>&1
{ link && started; } && ok "a save turns sshd on at once" || bad "runtime save: $(cat "$T/calls")"

echo "== a key line in authorized_keys alone; a link is not read"
reset; echo default > "$T/softlevel"
mkdir -p "$T/root/root/.ssh"; printf '%s\n' "$KEY" > "$T/root/root/.ssh/authorized_keys"
cfg apply > "$T/out" 2>&1
{ link && started; } && ok "authorized_keys with a key: sshd on" || bad "authorized_keys: $(cat "$T/calls")"
reset; echo default > "$T/softlevel"
mkdir -p "$T/root/root/.ssh"; printf '%s\n' "$KEY" > "$T/keys"; ln -s "$T/keys" "$T/root/root/.ssh/authorized_keys"
cfg apply > "$T/out" 2>&1
{ ! link && ! started; } && ok "authorized_keys as a link: not read, sshd off" || bad "link: $(cat "$T/calls")"
reset; echo default > "$T/softlevel"
mkdir -p "$T/root/root/.ssh"; printf 'not a key\n# comment\n' > "$T/root/root/.ssh/authorized_keys"
cfg apply > "$T/out" 2>&1
{ ! link && ! started; } && ok "authorized_keys with no key line: sshd off" || bad "no key line: $(cat "$T/calls")"

echo "== a key that tsx-config refuses"
reset; echo default > "$T/softlevel"
refused() { ! cfg "$@" > "$T/out" 2>&1 && ! grep -q 'cannot open\|not found' "$T/out"; }
refused set SSH_AUTHORIZED_KEY "not-a-key AAAA" && ok "set refuses a bad key" || bad "set and a bad key: $(cat "$T/out")"
refused set SSH_AUTHORIZED_KEY "ssh-ed25519 AAAA\$(reboot)" && ok "set refuses a key with a shell word" || bad "set and a shell word: $(cat "$T/out")"
cfg apply > "$T/out" 2>&1
{ ! link && ! started; } && ok "no valid key: sshd off" || bad "bad key: $(cat "$T/calls")"

echo "== SSH_SERVER"
reset; echo default > "$T/softlevel"
cfg set SSH_AUTHORIZED_KEY "$KEY" > /dev/null 2>&1; cfg apply > /dev/null 2>&1
cfg set SSH_SERVER off > "$T/out" 2>&1 && ok "set SSH_SERVER off" || bad "set off: $(cat "$T/out")"
cfg apply > "$T/out" 2>&1
{ ! link && ! started && grep -q 'rc-update del sshd default' "$T/calls" && grep -q 'rc-service sshd stop' "$T/calls"; } && ok "SSH_SERVER=off with a key: sshd off" || bad "off: $(cat "$T/calls")"
cfg set SSH_SERVER auto > /dev/null 2>&1; cfg apply > /dev/null 2>&1
{ link && started; } && ok "SSH_SERVER=auto with a key: sshd on again" || bad "auto: $(cat "$T/calls")"
refused set SSH_SERVER on && ok "set refuses SSH_SERVER=on" || bad "SSH_SERVER=on: $(cat "$T/out")"
refused set SSH_SERVER "off;reboot" && ok "set refuses a bad SSH_SERVER" || bad "a bad SSH_SERVER: $(cat "$T/out")"

echo "== the plugin writes only the link of sshd (and authorized_keys is the base's)"
reset; echo default > "$T/softlevel"
cfg set SSH_AUTHORIZED_KEY "$KEY" > /dev/null 2>&1; cfg apply > /dev/null 2>&1
other=$(cd "$T/root" && find . \( -type f -o -type l \) ! -path ./etc/runlevels/default/sshd ! -path ./root/.ssh/authorized_keys ! -path ./etc/init.d/sshd ! -path ./etc/shadow ! -path './etc/apk/*' | sort | tr '\n' ' ')
[ -z "$other" ] && ok "no other file in the test root" || echo "info: other files of apply in the test root: $other"
grep -v '^rc-update add sshd default$\|^rc-update del sshd default$\|^rc-service sshd \(status\|start\|stop\)$' "$T/calls" | grep -q . &&
	bad "other commands: $(cat "$T/calls")" || ok "only rc-update add/del sshd default and rc-service sshd status/start/stop"

[ $fails = 0 ] && echo "test-ssh-plugin: all ok" || echo "test-ssh-plugin: $fails failed"
[ $fails = 0 ]
