# uc_pxx_ssh.sh: the SSH plugin of tsx-config for the end-user build of a
# mainline payload (tools/mainline-payload/build.sh SSH_ACCESS=setup;
# docs/mainline-payload.md "SSH access"). It is a plugin of the folder
# /usr/local/lib/tsx/config.d (the contract is in tsx-config of
# tsx-linux-common, "plugins: the folder config.d").
#
# Such a build has no /root/.ssh/authorized_keys, and sshd is not in the
# default runlevel. The person adds an SSH public key in the "Access" part of
# the setup page (panel.conf SSH_AUTHORIZED_KEY). tsx-config checks the format
# of the key, and apply adds it to /root/.ssh/authorized_keys. This plugin
# then turns sshd on: apply adds sshd to the default runlevel and, when the
# default runlevel runs, starts it. At the next boot sshd starts as any
# service of the default runlevel.
#
# SSH_SERVER (auto, off or empty; empty is auto):
#   auto  sshd runs when root has an SSH key (panel.conf SSH_AUTHORIZED_KEY,
#         or a key line in /root/.ssh/authorized_keys)
#   off   sshd does not run, also with a key (apply stops it and takes it out
#         of the default runlevel)
#
# The plugin changes only the OpenRC runlevel link /etc/runlevels/default/sshd
# on the root file system and the state of the sshd service. It writes nothing
# else, and never the boot area of the eMMC.
#
# Test hooks: UC_PXX_SSH_RC_UPDATE and UC_PXX_SSH_RC_SERVICE (the commands),
# UC_PXX_SSH_SOFTLEVEL (the file of the OpenRC runlevel); PREFIX is the one of
# tsx-config (TSX_APPLY_PREFIX).
CFG_UC_PXX_SSH_KEYS="SSH_SERVER"
CFG_UC_PXX_SSH_SIG=

cfg_uc_pxx_ssh_valid() {
	case "$2" in ''|auto|off) return 0;; *) return 1;; esac
}

# uc_pxx_ssh_has_key: root has an SSH public key in the format that
# tsx-config accepts for SSH_AUTHORIZED_KEY
uc_pxx_ssh_has_key() {
	us_k=$(cfg_get SSH_AUTHORIZED_KEY 2>/dev/null) || us_k=
	if [ -n "$us_k" ] && val_ok SSH_AUTHORIZED_KEY "$us_k"; then
		return 0
	fi
	us_f="$PREFIX/root/.ssh/authorized_keys"
	[ -f "$us_f" ] && [ ! -L "$us_f" ] &&
		grep -Eq '^(ssh-[a-z0-9]+|ecdsa-sha2-[a-z0-9-]+) [A-Za-z0-9+/]+=*([[:space:]].*)?$' "$us_f" 2>/dev/null
}

cfg_uc_pxx_ssh_apply() {
	us_up=${UC_PXX_SSH_RC_UPDATE:-rc-update}
	us_svc=${UC_PXX_SSH_RC_SERVICE:-rc-service}
	us_lvl=$(cat "${UC_PXX_SSH_SOFTLEVEL:-/run/openrc/softlevel}" 2>/dev/null) || us_lvl=
	us_link="$PREFIX/etc/runlevels/default/sshd"
	us_mode=$(cfg_get SSH_SERVER 2>/dev/null) || us_mode=
	if [ "$us_mode" != off ] && uc_pxx_ssh_has_key; then
		if [ ! -e "$us_link" ] && [ ! -L "$us_link" ]; then
			if "$us_up" add sshd default >/dev/null 2>&1; then
				log "SSH: root has an SSH key: sshd is in the default runlevel now"
			else
				log "WARNING: SSH: rc-update add sshd default failed"
				return 1
			fi
		fi
		# In the boot runlevel (tsx-config at boot) the default runlevel
		# starts sshd later. After that (a save of the setup page), start it now.
		if [ "$us_lvl" = default ] && ! "$us_svc" sshd status >/dev/null 2>&1; then
			if "$us_svc" sshd start >/dev/null 2>&1; then
				log "SSH: sshd started"
			else
				log "WARNING: SSH: sshd did not start"
				return 1
			fi
		fi
	else
		if [ -e "$us_link" ] || [ -L "$us_link" ]; then
			if "$us_up" del sshd default >/dev/null 2>&1; then
				log "SSH: SSH_SERVER=off or no SSH key for root: sshd is not in the default runlevel now"
			else
				log "WARNING: SSH: rc-update del sshd default failed"
			fi
		fi
		if [ "$us_lvl" = default ] && "$us_svc" sshd status >/dev/null 2>&1; then
			"$us_svc" sshd stop >/dev/null 2>&1 && log "SSH: sshd stopped" || log "WARNING: SSH: sshd did not stop"
		fi
	fi
	return 0
}
