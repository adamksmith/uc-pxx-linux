#!/bin/sh
# Host test for uc-pxx-audio with a stub amixer and aplay. It checks the mixer
# defaults, the softvol controls, the volume steps (Master), the saved state and
# the one-time removal of the temporary Sendspin file.
set -u
HERE=$(cd "$(dirname "$0")/.." && pwd)
A=$HERE/overlay/usr/local/sbin/uc-pxx-audio
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
N=0 F=0
ok()  { N=$((N + 1)); echo "  ok: $*"; }
bad() { F=$((F + 1)); echo "  FAIL: $*"; }
eq() { if [ "$1" = "$2" ]; then ok "$3"; else bad "$3 (got '$1', want '$2')"; fi; }

busybox sh -n "$A" && ok "uc-pxx-audio passes busybox sh -n" || bad "busybox sh -n"
mkdir -p "$T/asound/UCP10" "$T/state"
cat > "$T/amixer" <<'STUB'
#!/bin/sh
echo "$*" >> "$AMIXER_LOG"
# the stub keeps Master in a file: "sset Master N%" writes it, "sget Master" prints it
case "$*" in
*"sset Master "*%) v=${*##* }; echo "${v%\%}" > "$AMIXER_LOG.master";;
*"sget Master"*) [ -s "$AMIXER_LOG.master" ] && echo "  Front Left: Playback $(cat "$AMIXER_LOG.master") [$(cat "$AMIXER_LOG.master")%] [0.00dB]";;
esac
exit 0
STUB
chmod 755 "$T/amixer"
printf '#!/bin/sh\necho "aplay $*" >> "$AMIXER_LOG"\n' > "$T/aplay"; chmod 755 "$T/aplay"
mkdir -p "$T/confd"
cat > "$T/audio.conf" <<'CONF'
SPEAKER_VOLUME=58
VOLUME_MAX=100
VOLUME_MIN=40
VOLUME_SENDSPIN=100
MIC_VOLUME=30
CONF
ua() { env -i PATH="$PATH" AMIXER="$T/amixer" APLAY="$T/aplay" UC_PXX_ALSA_CONFD="$T/confd" AMIXER_LOG="$T/log" TSX_BOARD_CONF="$HERE/overlay/usr/local/lib/tsx/board.sh" TSX_AUDIO_CONF="$T/audio.conf" TSX_ASOUND_DIR="$T/asound" \
	UC_PXX_STATE_DIR="$T/state" UC_PXX_CARD_WAIT=0 sh "$A" "$@"; }

echo "== init =="
: > "$T/log"; ua init >/dev/null 2>&1
eq "$(grep -c 'name=Left DAC Mux' "$T/log")" 1 "init sets the left DAC mux"
grep -q 'name=Right Line Mixer DACR1 Switch on' "$T/log" && ok "the right DAC goes to the right line out" || bad "no right line mixer"
grep -q 'name=PCM Playback Volume 100,100' "$T/log" && ok "init puts the codec at its ceiling VOLUME_MAX" || bad "codec not at VOLUME_MAX"
grep -q 'aplay .*-D tsx_master_ctl' "$T/log" && grep -q 'aplay .*-D tsx_media_ctl' "$T/log" && ok "init creates the Master and Media softvols" || bad "no softvol creation: $(grep aplay "$T/log")"
grep -q 'sset Master 58%' "$T/log" && ok "the first boot sets Master to SPEAKER_VOLUME %" || bad "no default Master: $(cat "$T/log")"
grep -q 'sset Media 100%' "$T/log" && ok "init sets Media to 100 %" || bad "no Media 100%"
[ "$(grep -n 'aplay' "$T/log" | head -1 | cut -d: -f1)" -lt "$(grep -n 'sset Master' "$T/log" | head -1 | cut -d: -f1)" ] && ok "the softvols exist before Master is set" || bad "Master set before the softvols"
grep -q 'name=ADC HPF Cut-off 0.0045xFs,0.0045xFs' "$T/log" && ok "the ADC high-pass filter is on" || bad "no ADC filter"
grep -q -e '-c UCP10' "$T/log" && ok "the card is UCP10" || bad "wrong card"

echo "== no card =="
rm -rf "$T/asound/UCP10"; : > "$T/log"
ua init >/dev/null 2>&1; eq "$?" 0 "init without a card exits 0"
eq "$(wc -c < "$T/log" | tr -d ' ')" 0 "init without a card sets nothing"
ua volume >/dev/null 2>&1; eq "$?" 2 "volume without a card exits 2"
mkdir -p "$T/asound/UCP10"

echo "== volume =="
eq "$(ua volume 50)" 50 "volume 50 prints 50"
eq "$(ua volume)" 50 "the volume (Master)"
eq "$(cat "$T/state/volume")" 50 "the state file"
: > "$T/log"; ua volume 100 >/dev/null
grep -q 'sset Master 100%' "$T/log" && ok "100 % is Master 100 %" || bad "100 %: $(cat "$T/log")"
grep -q 'PCM Playback Volume' "$T/log" && bad "volume changed the codec control" || ok "volume leaves the codec at its ceiling"
: > "$T/log"; ua volume 1 >/dev/null
grep -q 'sset Master 1%' "$T/log" && ok "1 % is Master 1 %" || bad "1 %: $(cat "$T/log")"
: > "$T/log"; ua volume 0 >/dev/null
grep -q 'sset Master 0%' "$T/log" && ok "0 % is Master 0 % (silence)" || bad "0 %: $(cat "$T/log")"
ua volume 40 >/dev/null; echo 70 > "$T/log.master"
eq "$(ua volume)" 70 "no argument prints Master as it is (another program set it), not the saved file"
eq "$(ua volume +5)" 75 "+5 steps from Master as it is"
eq "$(ua volume 90; ua volume +20)" "90
100" "+20 stops at 100"
eq "$(ua volume 5; ua volume -20)" "5
0" "-20 stops at 0"
ua volume 3x >/dev/null 2>&1; eq "$?" 2 "a bad number is refused"
ua volume +x >/dev/null 2>&1; eq "$?" 2 "a bad step is refused"

echo "== init with a saved volume, and fixed =="
ua volume 33 >/dev/null; : > "$T/log"; ua init >/dev/null 2>&1
grep -q 'sset Master 33%' "$T/log" && ok "init restores the saved volume on Master" || bad "no restore: $(cat "$T/log")"
ua volume 30 >/dev/null; : > "$T/log"; ua fixed
grep -q 'sset Master 100%' "$T/log" && ok "fixed sets Master to VOLUME_SENDSPIN" || bad "fixed: $(cat "$T/log")"
eq "$(cat "$T/state/volume")" 30 "fixed does not change the saved volume"

echo "== the temporary Sendspin file (60-tsx-media-temp.conf) =="
TMPF=$T/confd/60-tsx-media-temp.conf
printf '%s\n' 'pcm.tsx_dmix{type dmix ipc_key 51010 ipc_key_add_uid false ipc_perm 0666 slave{pcm "hw:UCP10,0" rate 48000 format S32_LE channels 4 period_size 480 buffer_size 3840} bindings{0 0 1 1 2 2 3 3}}' 'pcm.tsx_mono4{type route slave{pcm "tsx_dmix" channels 4} ttable{0{0 0.5 1 0.5 2 0.5 3 0.5} 1{0 0.5 1 0.5 2 0.5 3 0.5}}}' 'pcm.tsx_master{type softvol slave.pcm "tsx_mono4" control{name "Master" card UCP10} min_dB -50.0 max_dB 0.0 resolution 101}' 'pcm.tsx_media{type softvol slave.pcm "tsx_master" control{name "Media" card UCP10} min_dB -50.0 max_dB 0.0 resolution 101}' 'pcm.speaker{type plug slave.pcm "tsx_master"}' 'pcm.media{type plug slave.pcm "tsx_media"}' > "$TMPF"
eq "$(sha256sum "$TMPF" | cut -d' ' -f1)" 9cfe1081412147d0d6a93ae284e95f1c5e457c01bc087356bab8526c910de169 "the fixture is the file of the HANDOFF one-liner"
ua init >/dev/null 2>&1
[ ! -e "$TMPF" ] && ok "init removes the known temporary file" || bad "the temporary file is still there"
echo '# a file of the user' > "$TMPF"; ua init >/dev/null 2>&1
[ -e "$TMPF" ] && ok "init keeps a file of that name with other bytes" || bad "init removed a file of the user"
rm -f "$TMPF"; rm -rf "$T/asound/UCP10"; printf '%s\n' x > "$TMPF.x"; cp "$TMPF.x" "$TMPF"; rm -f "$TMPF.x"
ua init >/dev/null 2>&1; [ -e "$TMPF" ] && ok "(no card) a user file stays" || bad "no card: user file removed"
mkdir -p "$T/asound/UCP10"
echo "$N passed, $F failed"
[ "$F" = 0 ]
