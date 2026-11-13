# Mainline payload

The mainline payload is the input of the installer for a mainline install on
a UC-P10 (uc-pxx-installer, mainline mode). It holds the boot image of the
kernel without the vendor resource, the root file system and a manifest.
`tools/mainline-payload/build.sh` makes it on a build host. This page tells
the contract (version 2) and how to build the payload.

Nothing on this page touches a unit. The installer does all writes, with its
own checks and reviews. Read [boot.md](boot.md) and
[boot-control.md](boot-control.md) first.

## Contract v2

The P10-INSTALL drive holds a folder `uc-pxx-mainline/` with three files:

| File | Content |
|---|---|
| `manifest.json` | The manifest (below) |
| `boot-template.img` | An Android boot image of header version 0, made by `kernel/mkimage.sh` with an empty resource (the `second` part is empty). The header name is the build token. The device tree in the shim has `uc-pxx.id=<token>` in `/chosen/bootargs`. The kernel part is the shim (stub, device tree, Linux Image) of the pinned kernel |
| `rootfs.ext4` | The root file system for `system_a`: ext4, label `tsxroot`, the size a multiple of 512 bytes. The initramfs grows it to fill the partition on the first boot |

`manifest.json` (all sha256 values in lower-case hex, all sizes in bytes):

```json
{
  "schema": 2,
  "kind": "uc-pxx-mainline",
  "version": "<release tag or dev-<commit>>",
  "model": "UC-P10",
  "kernel": { "rev": "<kernel/KERNEL_REV.lts>" },
  "token": "<the header name of boot-template.img = uc-pxx.id>",
  "boot_template": { "file": "boot-template.img", "size": 0, "sha256": "" },
  "boot_assembled": { "resource_sha256": "290ef40577d434d702c3544076dbebd6ddd17e16087eff0e84c92549d67bb363",
                      "size": 0, "sha256": "" },
  "rootfs": { "file": "rootfs.ext4", "size": 0, "sha256": "", "label": "tsxroot" },
  "requires_bootchain": {
    "version": "1.0.0.94", "build_type": "userdebug",
    "uboot_sha256":  "c6e80c1590a44c9abd5756b8553787b84e096563f3726118949c44d1fe8d798c",
    "trust_sha256":  "a5ab4d9c5756b5b7f3e0860269207119733b4bc84e8d64600be9671ebb84a562",
    "dtbo_sha256":   "83b3e6321c43960bc4215635550a405b297ed965d7fc6ec548bb2b02d9d93629",
    "vbmeta_sha256": "7958c09b4fb6fb3d54a2382682074b4812e92cc1d81ca3183b20f03ff52f5f5c",
    "resource_sha256": "290ef40577d434d702c3544076dbebd6ddd17e16087eff0e84c92549d67bb363"
  },
  "vbmeta_patched": {
    "source_sha256": "7958c09b4fb6fb3d54a2382682074b4812e92cc1d81ca3183b20f03ff52f5f5c",
    "size": 8192,
    "sha256": "cebd4d8a68c8861b9801c4d83a14ab3d06f1d85b015a01686fae2d305a69f35e",
    "field_offset": 1088,
    "boot_image_size": 67108864
  },
  "vbmeta_boot_cap": 67108864
}
```

- `boot_assembled` is the predicted `boot_a`: the template with the stock
  resource of the unit (sha256 `290ef405...`) as the `second` part. The
  bytes are the bytes of `kernel/mkimage.sh --resource RESOURCE` with the same
  Image, device tree and token. The splice changes only the header fields
  `second_size`, `second_addr` (base + `0x00f00000`) and `id`, and appends the
  resource, padded to a page of 2048 bytes. The installer makes its own
  assembly with the resource of the keeper slot. It must get this sha256 and
  size, and the size must be at most `vbmeta_boot_cap`.
- `vbmeta_patched` is the vbmeta that `vbmeta_a` gets: the signed 1.0.0.94
  userdebug vbmeta (`source_sha256`, the `vbmeta_sha256` of the boot chain)
  with only the 8-byte `image_size` of its boot hash descriptor (at
  `field_offset`) changed from 38,029,312 to `boot_image_size`, 67,108,864
  (the size of `boot_a`). `tools/mainline-payload/vbmeta-patch.py` makes it;
  the bytes 1092 to 1094 change. The payload does not hold the file (it is a
  vendor file): the installer makes it again from the keeper's `vbmeta_b`
  and must get this sha256 and size.
- Why the patch: libavb loads only `image_size` bytes of `boot_a`, and U-Boot
  starts that buffer. The signed value is smaller than the mainline boot
  image. Unit 2 has started mainline from slot A with the same value in its
  `vbmeta_a` since 2026-10-24. The patch breaks the signature of the vbmeta.
  That adds no new dependency: the boot hash of a mainline image never
  matches the signed digest, so a mainline slot starts only on an unlocked
  unit (orange) in any case. On a locked unit, the slot fails the
  verification and the keeper starts.
- `vbmeta_boot_cap` is the `boot_image_size` of `vbmeta_patched`. The
  assembled image must not be larger.
- `requires_bootchain` is the boot chain of 1.0.0.94 userdebug that the
  mainline slot needs.
- The consumer refuses unknown keys, a schema other than 2 and a model other
  than `UC-P10`.

The payload never holds a vendor file. The template has no resource. The
assembled image and the patched vbmeta are computed on the build host only
for their sha256 and size, and then deleted.

## Where the parts come from

- **The boot template** is `/boot/uc-pxx-lts.img` of the kernel package
  `uc-pxx-kernel-lts` in the root file system. That is the image of
  `scripts/stage-kernel-uc-pxx.sh` of tsx-aports: `kernel/mkimage.sh` with an
  empty resource, the Image of `ci/build-kernel.sh` with the real initramfs
  built in (`rootfs/build-rootfs.sh initramfs`, with `rtl8363-init`, the
  reviewed `uc-pxx-bootctl` and `uc-pxx-reboot-syscall` of the tools bundle).
  So the slot boots the kernel that its root file system ships, and
  `uc-pxx-update-boot status` finds `boot_a` = the package image. The build
  checks that the template is of the reviewed kernel pin, and that
  `kernel/mkimage.sh` of the commit makes the template again, byte for byte,
  from its own Linux Image and the device tree of the package. The token is
  the token of that kernel build.
- **The root file system** is `rootfs/build-rootfs.sh all` (profile `ha`,
  the packages of the apk tree in the snapshot).
- **The manifest** is `tools/mainline-payload/payload.py manifest`. It checks
  every part again: the pin, the template layout and token, the stock
  resource, its own assembly against the image of `kernel/mkimage.sh
  --resource`, the ext4 superblock, the label and the size of the rootfs.

The kernel pin is the reviewed `d02e92631f2810a4a43fb6f09824afb9b0044ee2`.
`build.sh` and `payload.py` refuse any other pin. A new pin needs a review
and a change of `REVIEWED_KERNEL_REV` in both.

## Build

On the build host, in a clean checkout (the build copies the commit with `git
archive`, so a file that is not committed never gets into the payload):

```
# 1. once, with network: the input snapshot
tools/mainline-payload/build.sh prime --snapshot SNAP --channel https://tsx-aports.unexceptional.net/testing

# 2. no network: a dev build. It writes OUT/inputs.txt
tools/mainline-payload/build.sh build --snapshot SNAP --resource RESOURCE --vbmeta VBMETA --out OUT \
    --apk-url https://tsx-aports.unexceptional.net/testing [--authorized-keys KEYS]

# 3. a reproduction: the same bytes from the same inputs, in another folder
tools/mainline-payload/build.sh build --snapshot SNAP --resource RESOURCE --vbmeta VBMETA --out OUT2 \
    --inputs OUT/inputs.txt [--authorized-keys KEYS]
```

- `prime` fetches the published apk tree of tsx-aports into `SNAP/tsx`, then
  runs one rootfs build through `apk-snapshot.py serve`: every Alpine file
  that the build asks for is kept in `SNAP/alpine`, in the layout of the
  mirror, with the first `APKINDEX.tar.gz` of each repository. The Python
  files of `install-lva.sh` go to `SNAP/pip`.
- `build` runs the build container with `--network none` and reads only the
  snapshot. The inputs file records the commit, the pins, the digest of the
  container image and the digests of the three snapshot folders. With
  `--inputs` every value must match, or the build stops.
- `RESOURCE` is the stock resource (sha256 `290ef405...`), `VBMETA` the
  signed vbmeta of 1.0.0.94 userdebug (sha256 `7958c09b...`). Both are vendor
  files and stay on the build host.
- `--headroom MIB` is the free space in `rootfs.ext4` (`IMG_HEADROOM_MB` of
  `mkrootfs.sh`). The default is 0, so that the payload fits the P10-INSTALL
  drive; `mkrootfs.sh` adds 5 % of the content, and the initramfs grows the
  file system to fill `system_a` on the first boot.
- `--authorized-keys FILE` bakes ssh public keys for root into the rootfs
  (`/root/.ssh/authorized_keys`; the release workflow uses the secret
  `TSX_AUTHORIZED_KEYS`). The root password stays locked, so the login is by
  key only. A payload with keys is for the units of the key owner only, and
  `build-info.txt` says so. The inputs record the sha256 of the file; a
  reproduction needs the same file. Without it the image has no ssh key and a
  locked root password ([rootfs.md](rootfs.md) "Root login"). Never give a
  private key: the build refuses a file with `PRIVATE KEY` in it.
- `--step2-bootctl-inst FILE` is a separate option, off by default (step 2
  of the mainline install, MAINLINE-STEP2-DESIGN Q-S8). `FILE` must be
  `uc-pxx-bootctl-inst` r2 (sha256 `20aa6bc5...`); the rootfs gets it at
  `/usr/libexec/uc-pxx-step2/uc-pxx-bootctl-inst` (root, mode 0700)
  ([rootfs.md](rootfs.md) "uc-pxx-bootctl-inst in a step-2 build"). Today the
  safety rules allow that tool in no slot, and the installer gate refuses such
  a payload: it is for no unit before its rules line. The inputs record its
  sha256 (`STEP2_BOOTCTL_INST_SHA256`, `none` without the option).
- `--dev-apk-key NAME.rsa.pub` (TEST ONLY) lets the rootfs build install uc-pxx
  packages of a private build that are not published yet (for example the
  both-slot packages of tsx-aports before their tag): the snapshot's `tsx/`
  tree holds them, signed by a key of the build host. The build trusts that
  key for the package install only. The image never trusts it (its
  `/etc/apk/keys` holds only the project key) and has `/etc/tsx/dev-apk-key`;
  `build-info.txt` says "DEV PACKAGES". tsx-autoupdate of such an image
  starts in manual mode (`MODE=manual` in `/etc/tsx/autoupdate.conf`), so it
  never updates itself from the channel. The inputs record the sha256 of the key
  (`DEV_APK_KEY_SHA256`, `none` without it). Never publish such a payload.
- `--require-both-slot` stops the build unless the payload is a both-slot
  build of the commit (below).
- `--autoupdate-mode manual|auto` (default `manual`) sets the tsx-autoupdate
  mode of the slot. `manual` writes `MODE=manual` and `AUTO_RESTART=off` into
  `/etc/tsx/autoupdate.conf`: the slot never installs by itself, and an
  install from Home Assistant (or `tsx-autoupdate now`) does not restart the
  unit. Home Assistant then shows "Restart required", and the person picks the
  time of the restart. `UPDATE_MODE` and `UPDATE_AUTO_RESTART` of panel.conf
  still win. The inputs record it (`AUTOUPDATE_MODE`).
- `--ssh-access keys|setup` sets how root gets in over ssh (below, "SSH
  access"). The default is `keys` with `--authorized-keys`, else `setup`. The
  inputs record it (`SSH_ACCESS`).

The inputs format is `uc-pxx-mainline-payload-inputs-7`.

### SSH access

A payload comes in one of two forms:

- `keys`, the maintainer build: the keys of `--authorized-keys` are in
  `/root/.ssh/authorized_keys`, and sshd is in the default runlevel. Such a
  payload is for the units of the key owner only.
- `setup`, the end-user build: no ssh key, the root password locked, and sshd
  is not in the default runlevel. The person adds an SSH public key in the
  "Access" part of the setup page (panel.conf `SSH_AUTHORIZED_KEY`).
  tsx-config checks the format of the key, and `tsx-config apply` adds it to
  `/root/.ssh/authorized_keys`. The tsx-config plugin
  `/usr/local/lib/tsx/config.d/uc_pxx_ssh.sh` (`rootfs/ssh/uc_pxx_ssh.sh`)
  then adds sshd to the default runlevel and starts it. The panel.conf key
  `SSH_SERVER=off` keeps sshd off, also with a key. sshd of this build takes
  keys only: `/etc/ssh/sshd_config.d/00-uc-pxx-key-only.conf` sets
  `PasswordAuthentication no` and `KbdInteractiveAuthentication no` (the file
  sorts before `tsx.conf` of tsx-base, and sshd keeps the first value). A root
  password of the setup page is for the console only. The plugin changes only the
  runlevel link of sshd on the root file system and the sshd service. It
  writes nothing to the boot area of the eMMC. The test is
  `rootfs/tests/test-ssh-plugin.sh`.

### Both-slot build

A payload can go into slot B only when its rootfs and its initramfs hold the
both-slot boot control (MAINLINE-STEP2-DESIGN section 10). `payload.py
both-slot` compares, byte for byte with the commit of the build: the
boot-control, slot and data files of the rootfs (from the packages
uc-pxx-boot-tools and uc-pxx-board), and `/init`, `rcS`, `uc-pxx-findfs`,
`uc-pxx-install-rootfs`, the `tsx-data-backup` wrapper, `uc-pxx-rescue-help`,
`uc-pxx-slot` and `uc-pxx-reboot` of the initramfs in the Linux Image of the
kernel package, with their modes. `uc-pxx-bootctl` and `uc-pxx-update-boot`
(not in this repository) must have the shas pinned in `payload.py`.
`/usr/share/uc-pxx/boot-control.sha256` must list exactly the eight files of
the both-slot boot control and match them, the fstab must be the commit's
(no root or `/data` line), and no `uc-pxx-bootctl-inst`, step-2 or DEV-overlay
marker and no doubled cpio entry may be there. "yes" means "the bytes of this
commit and of the two pinned binaries"; it is not a review: only the
installer's gate pins decide what may be installed into slot B. The verdict goes to `both-slot.txt` (one line
per file with its sha256) and to `build-info.txt`. A build with the packages of
an older release says "both-slot build: NO": that payload is for slot A only.

The outputs in `OUT`:

| File | Content |
|---|---|
| `uc-pxx-mainline/` | The payload folder. When the assembled image is larger than `vbmeta_boot_cap`, the folder is `uc-pxx-mainline.OVER-CAP/` and the exit status is 3: never give such a folder to the installer |
| `inputs.txt` | The inputs of the build (the format is in the header of `build.sh`) |
| `build-info.txt` | Sizes, the cap verdict, the drive verdict, the initramfs facts |
| `rootfs.manifest`, `rootfs.sizes` | The package versions and sizes of the rootfs |
| `both-slot.txt` | The both-slot check (above): each file, its sha256 and the verdict |
| `SHA256SUMS` | The payload files, `inputs.txt` and `rootfs.manifest` |

### What makes the build reproducible

- `SOURCE_DATE_EPOCH` (the commit time in a dev build): `mkrootfs.sh` sets no
  file time after it, sets the shadow day to its day, packs the tarball in
  name order with `gzip -n`, and `mke2fs` takes its times from it.
- `ROOTFS_UUID`: the UUID, the metadata checksum seed and the directory hash
  seed of `rootfs.ext4`. A dev build derives it from the version and the time.
- `TSX_BUILD_ID` is the version, not the build time.
- The build container is `alpine@sha256:e311ae74...` (linux/arm64), checked by
  its image id.
- The Alpine packages come from the frozen snapshot, the tsx packages from the
  frozen apk tree, the Python files from the pinned, checked cache.
- `kernel/mkimage.sh` runs on the host. The inputs record the versions of the
  cross compiler, the linker, dtc and the sha256 of mkbootimg.

## Size limits

- `boot_assembled` must be at most `vbmeta_boot_cap` (67,108,864 bytes, the
  patched vbmeta; 38,029,312 bytes for the signed one). `build-info.txt`
  gives the margin or the excess.
- The P10-INSTALL drive is a RAM drive of 1200 MiB (FAT). `build-info.txt`
  says if the payload folder fits.

Measured on 2026-11-09 with the kernel package 6.18.54-gd02e92631f28 (token
`ucpxx-dfdcdfd8`) and the `ha` profile of the testing channel:

| Part | Bytes | Limit |
|---|---|---|
| `boot-template.img` | 34,586,624 | - |
| `boot_assembled` (+ the stock resource, 6,255,104 bytes, page-padded) | 40,843,264 | 38,029,312: **2,813,952 bytes over** |
| `rootfs.ext4` (content 1034 MiB, `IMG_HEADROOM_MB` 256) | 1,406,140,416 (1341 MiB) | - |
| the payload folder | 1373 MiB | 1200 MiB: **174 MiB over** |

So that build gave `uc-pxx-mainline.OVER-CAP/` under contract v1. Contract v2
(the patched vbmeta, cap 67,108,864) and `--headroom 0` (the default) remove
both excesses; `build-info.txt` of each build gives its sizes. The initramfs is only about
2 MB of the Image (xz). The excess must come out of the kernel Image or the
boot image layout, or the vbmeta changes. The rootfs fits the drive with a
small `IMG_HEADROOM_MB` (the initramfs grows the file system on the first
boot anyway) or compressed.

## Tests

`kernel/tests/test-mainline-payload.sh` checks the template and assembly
layout with made-up inputs (the assembly of `payload.py` equals
`kernel/mkimage.sh --resource` byte for byte), the refusals of
`check-template` and of the manifest generator, and that `build.sh` refuses a
checkout with another kernel pin. `UC_PXX_RESOURCE=FILE` adds a whole
made-up manifest against the contract.

## The USB set (both-slot builds)

A both-slot payload (`--require-both-slot`) needs `--xfer-bin` (the pinned
`uc-pxx-xfer`): the image then has the USB interface of [usb.md](usb.md). The
inputs file (format 6) records `XFER_BIN_SHA256`; `payload.py both-slot` checks
the set (`usb=yes`).
