#!/bin/sh
# Mark this slot's boot successful once the system has been healthy for a while, like Android's
# update_verifier + boot_control markBootSuccessful(). Until then the slot stays "trying", so a bad image
# keeps using up its tries and U-Boot falls back to the other slot.
# Started in the background by /etc/init.d/uc-pxx-boot-ok. It marks only the slot that U-Boot started
# (uc-pxx-slot: androidboot.slot_suffix of the U-Boot command line), slot A or slot B. Without that word (a
# `fastboot boot` RAM boot has none) it marks nothing.
#
# Off switches: kernel cmdline "uc-pxx.nomark", or the file /etc/uc-pxx-nomark (dev/test images).
# Image identity: the word uc-pxx.id=TOKEN on the kernel command line (kernel/mkimage.sh puts it into the
# device tree of the boot image) must equal the name field of the header of the booted slot's boot
# partition (boot_a or boot_b), so a `fastboot boot` RAM boot never blesses whatever happens to be there.
# The token comes ONLY from /proc/cmdline, never from a file of the root file system (the root file system
# is not part of the running image).

# Health (owner Q-T7, 2026-11-11): generic only, so the unit may run any software. The boot is healthy
# when it has been up HEALTH_SECS, the OpenRC default runlevel has finished starting (whatever each
# service gave: a failed service does not block), and the kernel has had no oops. The network and sshd
# are logged, never waited for and never a reason not to mark; no kiosk check. A broken-network build is
# then marked good and loses its automatic fallback (accepted by the owner: recovery is over the cable).
HEALTH_SECS=60
RUNLEVEL_WAIT_SECS=600

log() { echo "uc-pxx-mark-boot: $*" > /dev/kmsg; }

if grep -qw uc-pxx.nomark /proc/cmdline || [ -e /etc/uc-pxx-nomark ]; then
	log "marking disabled (uc-pxx.nomark / /etc/uc-pxx-nomark), slot left as is"
	exit 0
fi
TOKEN=
# no glob expansion: a cmdline word must never match a file in the root fs
set -f
for w in $(cat /proc/cmdline); do
	case $w in uc-pxx.id=*) [ -n "$TOKEN" ] || TOKEN=${w#uc-pxx.id=};; esac
done
set +f
if [ -z "$TOKEN" ]; then
	log "no uc-pxx.id= on the kernel command line, NOT marking"
	exit 1
fi
if ! SLOT=$(/usr/sbin/uc-pxx-slot); then
	log "no booted slot (no androidboot.slot_suffix in /proc/device-tree/chosen/u-boot,bootargs: a RAM boot?), NOT marking"
	exit 1
fi

while [ "$(cut -d. -f1 /proc/uptime)" -lt "$HEALTH_SECS" ]; do sleep 5; done

# The default runlevel has finished starting: OpenRC writes "default" to /run/openrc/softlevel and makes
# /run/openrc/rc.starting when it starts the runlevel, and removes rc.starting when the last service of it
# has been started (or has failed). This hook is started by uc-pxx-boot-ok, a service of that runlevel,
# so rc.starting is there before the hook runs: the test cannot pass early. A shutdown (rc.stopping, or
# another softlevel) never counts. A service that never returns keeps the runlevel starting: after
# RUNLEVEL_WAIT_SECS no mark (the slot stays trying).
runlevel_done() {
	[ "$(cat /run/openrc/softlevel 2>/dev/null)" = default ] && [ ! -e /run/openrc/rc.starting ] && [ ! -e /run/openrc/rc.stopping ]
}
waited=0
until runlevel_done; do
	if [ "$waited" -ge "$RUNLEVEL_WAIT_SECS" ]; then
		log "the OpenRC default runlevel has not finished starting after ${RUNLEVEL_WAIT_SECS}s, NOT marking (slot stays trying)"
		exit 1
	fi
	sleep 5
	waited=$((waited + 5))
done

# kernel taint bit 7 (D) = an oops/BUG happened; do not bless a kernel that has died once
if [ $(( $(cat /proc/sys/kernel/tainted) & 128 )) -ne 0 ]; then
	log "kernel oops seen (taint $(cat /proc/sys/kernel/tainted)), NOT marking"
	exit 1
fi

# log only (owner Q-T7): the network and sshd are not part of the health rule
net=
ip -f inet addr show dev eth0 2>/dev/null | grep -q "inet " && net=eth0
ip -f inet addr show dev usb0 2>/dev/null | grep -q "inet " && net="${net:+$net,}usb0"
pidof sshd >/dev/null 2>&1 && ssh=yes || ssh=no
log "healthy: up $(cut -d. -f1 /proc/uptime) s, default runlevel started, no oops (log only: IPv4 on ${net:-none}, sshd $ssh)"

# F1: never race the flash wrapper or uc-pxx-arm-slot. They hold this lock while they arm slot A, and they
# leave /run/uc-pxx-slot-a-changed behind: once boot_a or system_a has been changed under this running
# image, this (old) image must never mark slot A. The marker of the booted slot is the one that counts.
exec 9>/run/uc-pxx-abdata.lock
if ! flock -n 9; then
	log "A/B lock busy (flash in progress), NOT marking"
	exit 1
fi
if [ -e "/run/uc-pxx-slot-$SLOT-changed" ]; then
	log "slot $SLOT was changed during this boot, NOT marking"
	exit 1
fi
/usr/sbin/uc-pxx-bootctl mark-successful --expect "$SLOT" --token "$TOKEN"
rc=$?
flock -u 9
case $rc in
	0) log "boot marked successful (or already was)" ;;
	1) log "uc-pxx-bootctl refused, slot left as is" ;;
	2) log "uc-pxx-bootctl I/O error, original A/B sector verified intact" ;;
	*) log "!!! uc-pxx-bootctl rc $rc: A/B STATE UNKNOWN - DO NOT REBOOT, inspect LBA 49156 !!!"
	   echo 1 > /sys/class/leds/red/brightness 2>/dev/null ;;
esac
exit $rc
