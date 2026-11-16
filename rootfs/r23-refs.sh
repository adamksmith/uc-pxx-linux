# shellcheck shell=sh
# r23-refs.sh: the R23 reference trees, their content manifests and the
# profile bundles (DESIGN-R23 §3.2, §4.6, §5, §7.2). Sourced by mkrootfs.sh
# (an R23 base build, UC_PXX_PROVISION_BIN) after the base tree $R is complete,
# before the SOURCE_DATE_EPOCH step and the images: it uses mkrootfs.sh's
# variables (R, OUT, HERE, TOP, ALPINE, ARCH, MIRROR, TSX_APK_LOCAL, DEV,
# TSX_BUILD_ID, STEP2_INST_SHA256, STEP2_BIN_SHA256, PROV_SHA256) and its
# function profile_pkgs. Runs INSIDE the build container, as root, with no
# network.
#
# For each profile (console, kiosk, kiosk-ha = the profile.sh profile ha):
#   1. a copy of the base tree;
#   2. kiosk and kiosk-ha: the package list of `apk add --simulate` of the
#      profile's names (profile_pkgs) against the snapshot; the bundle's
#      repository (bundle.py repo: the four signed indexes and those .apk files
#      of the snapshot, byte for byte); then the install as on the unit: the
#      base's own apk in the tree (chroot), with --no-network and only the
#      bundle's repository; kiosk-ha: /opt/lva built and packed (lva-build.sh);
#   3. the profile steps as on the unit: the base's own
#      /usr/share/uc-pxx-provision/profile-apply.sh in the tree (chroot);
#   4. the content manifest of the reference B (contentmanifest.py, the pinned
#      exclusion list r23/content-exclude.txt): ref_b; the bundle (bundle.py
#      make, checked again as the unit reads it);
#   5. step 2's pinned difference (r23/clone-delta.json, build id
#      RELEASE-PROFILE), the forbidden search (no r2, uc-pxx-step2 or
#      uc-pxx-provision anywhere), the content manifest of the reference A:
#      ref_a.
# The console reference B must be the base itself (its manifest before and
# after the profile steps are equal). Then profiles.json goes into the base:
# the bundles, ref_b, ref_a and the installed list of each profile.
# Outputs in $OUT/r23: the bundles (uc-pxx-profile-NAME-RELEASE.tar, and
# their bundle.json as .tar.json), ref-b-NAME.manifest, ref-a-NAME.manifest,
# installed-NAME.txt, profiles.json, refs.txt (KEY=VALUE), build logs.

r23_refs() {
	R23_REL=$UC_PXX_R23_RELEASE
	case $R23_REL in ''|*[!A-Za-z0-9._+-]*) echo "ERROR: UC_PXX_R23_RELEASE '$R23_REL'"; exit 1;; esac
	[ -d "$MIRROR/$ALPINE/main/$ARCH" ] || { echo "ERROR: the R23 references need a local snapshot mirror (UC_PXX_APK_MIRROR), not $MIRROR"; exit 1; }
	log "R23 references (release $R23_REL)"
	apk add -q --no-cache python3 >/dev/null || { echo "ERROR: no python3 for the R23 tools (the snapshot mirror)"; exit 1; }
	T=$TOP/tools/mainline-payload
	PY="python3 -I"
	EXCL=$T/r23/content-exclude.txt DELTA=$T/r23/clone-delta.json
	EXCL_SHA=$($PY "$T/contentmanifest.py" exclude-sha256 "$EXCL") || exit 1
	DELTA_SHA=$(sha256sum "$DELTA" | cut -d' ' -f1)
	O=$OUT/r23
	rm -rf "$O"; mkdir -p "$O"
	cp "$R/lib/apk/db/installed" /build/base.installed
	printf '%s/%s/main\n%s/%s/community\n%s/%s/common\n%s/%s/uc-pxx\n' "$MIRROR" "$ALPINE" "$MIRROR" "$ALPINE" \
		"$TSX_APK_LOCAL" "$ALPINE" "$TSX_APK_LOCAL" "$ALPINE" > /build/snap.repositories
	# the files that A must not hold anywhere (DESIGN-R23 §4.4)
	S2SIZE=$(stat -c %s "$R/$STEP2_BIN_PATH") PSIZE=$(stat -c %s "$R/$PROV_BIN_PATH")
	FORBID="--forbid uc-pxx-bootctl-inst:777976:$STEP2_INST_SHA256 --forbid uc-pxx-step2:$S2SIZE:$STEP2_BIN_SHA256 --forbid uc-pxx-provision:$PSIZE:$PROV_SHA256"
	KEEPSHA=
	for f in "$STEP2_INST_PATH" "$STEP2_BIN_PATH" "$PROV_BIN_PATH" "$XFER_PATH" usr/sbin/uc-pxx-bootctl usr/sbin/uc-pxx-update-boot; do
		KEEPSHA="$KEEPSHA --new-sha256 $(sha256sum "$R/$f" | cut -d' ' -f1)"
	done
	{
		echo "R23_RELEASE=$R23_REL"
		echo "BASE_VERSION=${TSX_BUILD_ID:-}"
		echo "CONTENT_EXCLUDE_SHA256=$EXCL_SHA"
		echo "CLONE_DELTA_SHA256=$DELTA_SHA"
	} > "$O/refs.txt"
	PROFARGS=
	for name in console kiosk kiosk-ha; do
		case $name in kiosk-ha) p=ha;; *) p=$name;; esac
		X=/build/ref-$name
		log "R23 reference $name (profile $p)"
		rm -rf "$X"; cp -a "$R" "$X"
		LVA= TARARGS=
		if [ "$name" != console ]; then
			profile_pkgs "$p" | tr ' ' '\n' | grep . > /build/$name.add
			# shellcheck disable=SC2046 # the names
			apk add --simulate --root "$X" --no-network --no-cache --repositories-file /build/snap.repositories \
				$(cat /build/$name.add) > /build/$name.sim 2>&1 || { tail -20 /build/$name.sim; echo "ERROR: apk add --simulate ($name)"; exit 1; }
			$PY "$T/bundle.py" simulate-list /build/$name.sim /build/$name.list || exit 1
			rm -rf /build/repo-$name
			$PY "$T/bundle.py" repo --alpine-dir "$MIRROR" --tsx-dir "$TSX_APK_LOCAL" --branch "$ALPINE" \
				--list /build/$name.list --out /build/repo-$name || exit 1
			# the install of the unit: the base's apk, no network, only the bundle
			mkdir -p "$X/tmp/r23"
			cp -a /build/repo-$name "$X/tmp/r23/repo"
			sed 's#^#/tmp/r23/repo/#' /build/repo-$name/repositories > "$X/tmp/r23/repositories"
			# shellcheck disable=SC2046 # the names
			chroot "$X" /sbin/apk add --no-network --no-cache --repositories-file /tmp/r23/repositories \
				$(cat /build/$name.add) > "$O/apk-$name.log" 2>&1 || { tail -30 "$O/apk-$name.log"; echo "ERROR: the bundle install ($name)"; exit 1; }
			rm -rf "$X/tmp/r23"
			grep -E '^[A-Za-z0-9]' "$X/etc/apk/world" > /build/$name.world
			if sh "$HERE/profile.sh" has "$p" step lva; then
				sh "$HERE/lva-build.sh" "$X" /build/lva-$name.tar > "$O/lva-$name.log" 2>&1 || { tail -30 "$O/lva-$name.log"; exit 1; }
				LVA=/build/lva-$name.tar
			fi
		fi
		# the profile steps of the unit: the base's own script, in the tree
		[ "$name" != console ] || $PY "$T/contentmanifest.py" build "$X" --exclude "$EXCL" --out /build/console-before.manifest > /dev/null || exit 1
		mkdir -p "$X/tmp/r23"
		A=
		if [ -n "$LVA" ]; then cp "$LVA" "$X/tmp/r23/lva.tar"; A="--lva /tmp/r23/lva.tar"; fi
		# shellcheck disable=SC2086 # empty or two words
		chroot "$X" /bin/sh /usr/share/uc-pxx-provision/profile-apply.sh "$p" / $A > "$O/apply-$name.log" 2>&1 ||
			{ tail -30 "$O/apply-$name.log"; echo "ERROR: the profile steps ($name)"; exit 1; }
		rm -rf "$X/tmp/r23"
		B=$($PY "$T/contentmanifest.py" build "$X" --exclude "$EXCL" --out "$O/ref-b-$name.manifest" | cut -d' ' -f1) || exit 1
		[ -n "$B" ] || exit 1
		# no Rockchip resource in the tree (payload.py scan-tar of the base, here
		# for every reference; the vendor names: build.sh, ci/check-no-proprietary.sh)
		$PY "$T/payload.py" scan-dir "$X" || { echo "ERROR: the reference B of $name holds a Rockchip resource"; exit 1; }
		if [ "$name" != console ]; then
			# no package of the bundle changes a file of the base (the boot control,
			# the kernel, the step-2, USB and provisioning sets ...) or adds a uc-pxx-*
			# name or a pinned binary; only the files that apk and the profile steps
			# change may differ
			$PY "$T/contentmanifest.py" keep "$O/ref-b-console.manifest" "$O/ref-b-$name.manifest" \
				--allow /etc/apk/world --allow /etc/group --allow /etc/group- --allow /etc/passwd --allow /etc/passwd- \
				--allow /etc/inittab --allow /etc/tsx/profile --allow /lib/apk/db/installed \
				--allow /lib/apk/db/scripts.tar.gz --allow /lib/apk/db/triggers --allow /lib/apk/db/lock \
				--new-name-prefix uc-pxx- $KEEPSHA > "$O/keep-$name.txt" || { cat "$O/keep-$name.txt"; echo "ERROR: the bundle of $name changes the base"; exit 1; }
			cat "$O/keep-$name.txt"
		fi
		if [ "$name" = console ]; then
			cmp -s /build/console-before.manifest "$O/ref-b-$name.manifest" ||
				{ $PY "$T/contentmanifest.py" diff /build/console-before.manifest "$O/ref-b-$name.manifest"; echo "ERROR: the console profile steps change the base"; exit 1; }
			rm -f /build/console-before.manifest
		fi
		INST=$($PY "$T/bundle.py" installed-sha256 "$X/lib/apk/db/installed" | cut -d' ' -f1) || exit 1
		awk '/^P:/ { p = substr($0, 3) } /^V:/ { print p "-" substr($0, 3) }' "$X/lib/apk/db/installed" | LC_ALL=C sort > "$O/installed-$name.txt"
		if [ "$name" != console ]; then
			F=$O/uc-pxx-profile-$name-$R23_REL.tar
			# shellcheck disable=SC2086 # empty or two words
			$PY "$T/bundle.py" make --repo /build/repo-$name --list /build/$name.list --before /build/base.installed \
				--after "$X/lib/apk/db/installed" --world /build/$name.world --add /build/$name.add --profile "$name" \
				--release "$R23_REL" ${LVA:+--lva "$LVA"} --out "$F" > "$O/bundle-$name.txt" || exit 1
			cat "$O/bundle-$name.txt"
			$PY "$T/bundle.py" check "$F" || exit 1
			TARARGS=":$F:$F.json"
			rm -rf /build/repo-$name
		fi
		# the reference A: step 2's difference
		$PY "$T/contentmanifest.py" apply-delta "$DELTA" "$X" "$R23_REL-$name" || exit 1
		# shellcheck disable=SC2086 # the --forbid options
		$PY "$T/contentmanifest.py" build "$X" --exclude "$EXCL" --full $FORBID > /dev/null || { echo "ERROR: the reference A of $name holds a forbidden file"; exit 1; }
		RA=$($PY "$T/contentmanifest.py" build "$X" --exclude "$EXCL" --out "$O/ref-a-$name.manifest" | cut -d' ' -f1) || exit 1
		KEY=$(echo "$name" | tr 'a-z-' 'A-Z_')
		{
			echo "REF_B_$KEY=$B"
			echo "REF_A_$KEY=$RA"
			echo "INSTALLED_$KEY=$INST"
			[ "$name" = console ] || echo "BUNDLE_$KEY=$(sha256sum "$F" | cut -d' ' -f1)"
			[ "$name" = console ] || echo "INDEX_$KEY=$(sha256sum "$F.json" | cut -d' ' -f1)"
			[ -z "$LVA" ] || echo "LVA_$KEY=$(sha256sum "$LVA" | cut -d' ' -f1)"
		} >> "$O/refs.txt"
		log "R23 reference $name: ref_b $B, ref_a $RA"
		PROFARGS="$PROFARGS --profile $name:$p:$B:$RA:$INST$TARARGS"
		rm -rf "$X"
		[ -z "$LVA" ] || rm -f "$LVA"
	done
	URLARGS=
	for u in $UC_PXX_PROVISION_URLS; do URLARGS="$URLARGS --url $u"; done
	# shellcheck disable=SC2086 # option lists
	$PY "$T/bundle.py" profiles --release "$R23_REL" --base-version "${TSX_BUILD_ID:-}" --alpine "$ALPINE" \
		--exclude-sha256 "$EXCL_SHA" --delta-sha256 "$DELTA_SHA" $URLARGS $PROFARGS --out "$O/profiles.json" || exit 1
	install -m 644 -o 0 -g 0 "$O/profiles.json" "$R/usr/share/uc-pxx-provision/profiles.json"
	echo "PROFILES_JSON=$(sha256sum "$O/profiles.json" | cut -d' ' -f1)" >> "$O/refs.txt"
	rm -f /build/base.installed /build/snap.repositories /build/*.add /build/*.sim /build/*.list /build/*.world
	cat "$O/refs.txt"
}
