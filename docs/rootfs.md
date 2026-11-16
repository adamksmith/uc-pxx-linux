# Rootfs and userland

The UC-P10 runs a small Alpine Linux root file system. A build host makes it
as an ext4 image for `system_a`. This page tells how the image is built, what
the board files and services do, and what is still open. For the boot chain
see [boot.md](boot.md), for the kernel see [kernel.md](kernel.md), and for the
board see [hardware.md](hardware.md).

The userland is the one of the sister projects tsx-xx70-linux and
tsx-xx60-linux. Its parts that do not depend on the hardware (kiosk, panel
configuration, setup page, Home Assistant device, updates, screen blanking,
data partition) are the packages of tsx-linux-common. This repository holds
the parts that belong to the UC-P10.

## Build the image

```sh
rootfs/fetch-apk-tree.sh apk-tree      # the published apk tree (common and uc-pxx packages)
TSX_APK_LOCAL=$PWD/apk-tree rootfs/build-rootfs.sh rootfs   # out/rootfs.{tar.gz,ext4,manifest,sizes,sha256}
```

`rootfs/mkrootfs.sh` builds the rootfs inside an aarch64 Alpine container
under qemu-user (binfmt `qemu-aarch64`) on the build host. So the result is
native aarch64 code. Never run the build on the workstation.

The image comes from packages only. The build compiles nothing and copies no
software from the repository. `TSX_APK_LOCAL` is required. It names a local
copy of the published tree of the apk repository (tsx-aports).

The build does these steps:

1. Check the tree (`rootfs/check-apk-tree.sh`).
2. Install the Alpine packages of `rootfs/packages.txt`, the packages of
   `rootfs/packages-tsx.txt` and the profile package `uc-pxx-<profile>`.
3. Render the splash sizes of `UC_PXX_SPLASH_SIZES` with `splash/mksplash.sh`
   of tsx-linux-common (`TSX_COMMON`, default `../tsx-linux-common`). The
   variable is empty by default, so this step does nothing and the image has
   the images of the package ([boot.md](boot.md) "The boot splash").
4. Copy the image files of `rootfs/profiles/image.list` (`fstab`, `inittab`
   and the profile marker).
5. Add the users, enable the services of the profile and lock the root
   password.
6. Check the kernel package against the pin (`rootfs/check-kernel-pins.sh`).
7. Write the tarball and the ext4 image (label `tsxroot`).

`rootfs/out/rootfs.ext4` must be at most 1700 MiB. `system_a` has 1792 MiB.
The initramfs grows the file system to fill the partition at the first boot.

The initramfs is built into the kernel Image. `rootfs/build-rootfs.sh
initramfs` makes it ([boot.md](boot.md) "The boot initramfs").

### A reproducible build

With `SOURCE_DATE_EPOCH`, `TSX_BUILD_ID` and `ROOTFS_UUID` set, the same
inputs give the same `rootfs.tar.gz` and `rootfs.ext4`: no file time is after
`SOURCE_DATE_EPOCH`, the shadow day is its day, the tarball is in name order
(`gzip -n`), and the UUID and the hash seed of the file system are
`ROOTFS_UUID`. `UC_PXX_APK_MIRROR` names a local snapshot of the Alpine
mirror for the build container (the panel's `/etc/apk/repositories` keeps the
public mirror), `UC_PXX_DOCKER_NET=none` runs the container without network,
and `UC_PXX_PIP_CACHE` names the folder of the Python files of
`install-lva.sh`. `tools/mainline-payload/build.sh` sets all of them
([mainline-payload.md](mainline-payload.md)).

## Test build without the uc-pxx packages

A test build can use the files of this repository instead of the packages of
the category `uc-pxx`, for example to test a change before a package has it.
Never publish such an image.

```sh
UC_PXX_DEV_OVERLAY=1 PROFILE=console TSX_APK_LOCAL=$PWD/apk-tree \
  UC_PXX_BOOTCTL=uc-pxx-bootctl-aarch64 RTL8363_INIT=rtl8363-init \
  AUTHORIZED_KEYS=my-keys.pub rootfs/build-rootfs.sh rootfs
```

With `UC_PXX_DEV_OVERLAY=1` the build:

- needs only the category `common` in the apk tree, and skips
  `rootfs/check-apk-tree.sh`;
- installs the Alpine packages of the profile, `tsx-keys` and the common
  packages of `rootfs/dev/common-packages.list` (what the profile meta
  package will pull). It installs no `uc-pxx-*` package;
- copies `rootfs/overlay` and `packages/uc-pxx-leds/root` into the image;
- installs `UC_PXX_BOOTCTL` as `/usr/sbin/uc-pxx-bootctl`. The build stops
  if its sha256 is not the reviewed one ([boot-control.md](boot-control.md));
- installs `RTL8363_INIT` as `/usr/sbin/rtl8363-init`;
- does not start `tsx-autoupdate`. The published common packages have no
  board hook, and an update must arm slot A first;
- skips `rootfs/check-kernel-pins.sh`, because there is no kernel package.
  A staged module tree must come from the pinned kernel;
- writes the marker `/etc/tsx/dev-overlay`.

The published common packages can be older than the tsx-linux-common
checkout. With `UC_PXX_DEV_COMMON=1` and `TSX_COMMON`, the test build also
copies the script files of the checkout over the files of the installed
common packages (the `etc/` and `usr/` of each folder, which is the root of
one package, and the ESPHome shim to `/opt/lva/shim`). The compiled programs stay as
packaged. The files of `rootfs/overlay` win over these files. The list of the
copied files is in `/etc/tsx/dev-common-overlay`.

The boot image does not come from the image. Make it with
`kernel/mkimage.sh` from the same kernel build.

## Where the packages come from

The apk repository is `tsx-aports`. The UC-P10 uses two categories: `common`
for the shared packages and `uc-pxx` for the packages of this family. A panel
lists only these two repositories.

| Package | Content |
|---|---|
| `uc-pxx-board` | The board files of this repository (`rootfs/overlay`) and `rtl8363-init` |
| `uc-pxx-leds` | The LED package (`packages/uc-pxx-leds`): daemon, command, service and ESPHome plugin |
| `uc-pxx-kernel-lts` | The boot image `/boot/uc-pxx-lts.img` and the module tree |
| `uc-pxx-boot-tools` | The boot-control tools ([boot-control.md](boot-control.md)) |
| `uc-pxx-console`, `uc-pxx-kiosk`, `uc-pxx-ha` | The profile meta packages |

tsx-aports builds these packages in its category `uc-pxx`. The sources are
the tag `board-v<version>` of this repository and two release assets of
tsx-aports. The tools bundle holds the static programs `uc-pxx-bootctl`,
`uc-pxx-reboot-syscall` and `rtl8363-init`. The kernel bundle holds the boot
image without the resource for U-Boot, the device trees and the modules
([boot.md](boot.md) "The boot image"). The files in `rootfs/overlay` are the
sources of `uc-pxx-board`.

The site of tsx-aports has two channels:

| Channel | Address | Use |
|---|---|---|
| stable | `https://tsx-aports.unexceptional.net` | The default of every panel |
| testing | `https://tsx-aports.unexceptional.net/testing` | New packages before a person promotes them to stable |

A panel uses the testing channel when `APK_URL` in its panel configuration
names the testing address. `rootfs/fetch-apk-tree.sh` takes the address of
the channel as its second argument. The default is stable.

`rootfs/check-apk-tree.sh` stops the build and names the missing packages
when the tree does not have all the packages of the profile.

The board needs tsx-linux-common 0.3.12 or newer (`TSX_PKG_PREFIX` and the
board hooks of `tsx-autoupdate`). Use no older common.

## Profiles

A profile decides what the image holds. `rootfs/profiles/*.list` name the
packages, services, users and build steps. Each profile holds all the earlier
ones.

| Profile | Adds |
|---|---|
| `console` | A plain Linux system with a text login on the panel screen and SSH |
| `kiosk` | The Chromium kiosk, screen blanking, the on-screen keyboard and the setup page |
| `ha` (default) | The Home Assistant layer: ESPHome device, MQTT, voice satellite, Bluetooth proxy, Sendspin |

`rootfs/profile.sh` reads the lists. `mkrootfs.sh` and
`rootfs/tests/test-profiles.sh` both use it.

The profile steps after the package install are one script,
`rootfs/profile-apply.sh PROFILE ROOT [--lva FILE]` (DESIGN-R23 §3.5): `/opt/lva`
of the ha profile from a packed `lva.tar` (`rootfs/lva-build.sh` runs
`install-lva.sh` of tsx-ha in the build container and packs the result
reproducibly), root as the owner of `/etc` and `/usr/local`, the shared library
check, the users `kiosk` and `tsx-setup`, the hostname (only over a default
name), the trim, the fontconfig caches, the files of `profiles/image.list` (a
file the profile does not have is removed) and, last, the services of the
profile. `mkrootfs.sh` runs it on the image it builds; for a tree other than
`/` the script copies itself into the tree and runs there under `chroot`, so
the tree's own busybox does the work. An R23 base image ships the same script
in `/usr/share/uc-pxx-provision/` (`profile-apply.sh --install-set`), and the
unit's first-boot provisioning runs that copy ([mainline-payload.md](mainline-payload.md#r23-base-build)).

## Root login

A public image has no root password. The field in `/etc/shadow` is locked. The
installer sets a password or an SSH key. A test build can set a fixed password
with `TSX_DEV_ROOT_HASH`. Never publish such an image.

## Partitions and file systems

| Mount | Source | Note |
|---|---|---|
| `/` | `system_a` or `system_b` (the booted slot, by GPT name), ext4, label `tsxroot` | The initramfs checks it, grows it to fill the partition and mounts it (`rw,noatime,commit=60`) |
| `/data` | ext4, label `tsxdata` | Phase 2: `userdata` (by GPT name). Phase 1: the LVM volume `tsx/data` over `vendor_a` and `oem_a`. Mounted by `uc-pxx-lvm` |
| `/tmp` | tmpfs | |

The fstab has only the `/tmp` line. A line by `LABEL=` or `UUID=` is not
unique with mainline in both slots: `system_a` and `system_b` hold the same
image, and a unit can have two file systems with the label `tsxdata`. So the
initramfs mounts the root by its GPT name, and the service `uc-pxx-lvm` mounts
`/data` before `localmount`, by device and only after an exact check (ext4,
label `tsxdata`): `userdata` first, else the LVM volume. It never mounts a
`userdata` with another label (Android's data, or `tsxdata-new` of a step 2
that has not finished). [boot.md](boot.md) tells the phases.

The fstab is a file of the image (`profiles/image.list`), the service is a
file of the package `uc-pxx-board`, and the initramfs is in the kernel package.
A release that ships this fstab ships the service and the initramfs of the
same commit: an older `uc-pxx-lvm` only activates the volume group and does not
mount it.

Without a tsx data file system (a slot that the RAM installer wrote, before
step 2), `/data` is a folder of the root file system and `tsx-data` does
nothing. The image therefore has `/var/lib/tsx` (root, 0755, empty): the start
of `tsx-autoupdate` makes its state folder `/var/lib/tsx/autoupdate` in it
(`checkpath` makes no parent folder), and step 2 refuses while that folder is
missing. With `/data`, `tsx-data` moves it and binds `/data/var/lib/tsx` onto
it, as it did with the folder that its own `mkdir -p` made before. The build
fails if the folder is missing or not that.

### The data tools of step 2

Step 2 of the mainline install (MAINLINE-STEP2-DESIGN §6) makes `/data` on
`userdata` for both slots. Its two plan steps run
`/usr/sbin/uc-pxx-data-migrate` from the running, successful slot, after the
other slot is written and verified and before it is armed:

- `uc-pxx-data-migrate format --yes`: the whole partition is discarded, the
  first and the last MiB get zeros, and `mkfs.ext4 -L tsxdata-new -m 0`
  makes an empty file system. Nothing mounts `tsxdata-new`.
- `uc-pxx-data-migrate migrate --yes`: the panel services stop; all of
  `/data` and each folder of `tsx-data` go to the place that `tsx-data` uses
  (`/data/<folder>`, with the marker `.tsx-moved`), from `/data/<folder>`
  when `tsx-data` moved it already, else from the root file system. Each
  folder is compared by its tree digest. The three Wi-Fi/Bluetooth files go
  to `/data/uc-pxx/firmware` (`uc-pxx-firmware` reads them there first). The
  last step gives the file system the label `tsxdata` (the kernel ioctl
  `FS_IOC_SETFSLABEL` on the mounted file system: the image has no `e2label`).
- `status` and `check` only read. Both writing commands refuse a finished
  `/data` (exit 4), a mounted or held `userdata`, a node that is not the
  `userdata` of the layout (`mmcblk0p28`, start 16811008, 13724639 sectors),
  a RAM boot, a root that is not the partition of the booted slot, and a
  running fstab that mounts by label. A failure after the first write is exit
  3: the label is not `tsxdata`, nothing mounts the file system, the data of
  the root file system is unchanged, and both steps can run again.

`/usr/sbin/uc-pxx-data-release` gives `userdata` back ("put Android back",
§7.3): `copy --yes` puts `/data` back on the root file system of the running
slot (the markers removed) and sets the label `tsxdata-old`; after a restart,
`wipe --yes` writes zeros over the first and the last MiB.

### uc-pxx-bootctl-inst in a step-2 build

`uc-pxx-bootctl-inst` (the two-slot A/B tool of the installer) is never in a
normal image: `mkrootfs.sh` stops when any file of that name, or any file of
step 2 (`uc-pxx-step2*`), is in the tree. The separate build option
`UC_PXX_STEP2_BOOTCTL_INST` (off by default; the payload options
`--step2-bootctl-inst` and `--step2-bin`) makes a STEP-2 BUILD:

| Path | What |
|---|---|
| `/usr/libexec/uc-pxx-step2/` | root, mode 0700 |
| `…/uc-pxx-bootctl-inst` | the reviewed r2 binary (sha256 `20aa6bc5...`), 0700 |
| `…/uc-pxx-step2` | the pinned `uc-pxx-step2` of uc-pxx-installer (`UC_PXX_STEP2_BIN`, `ci/build-step2.sh`; the pin is in `mkrootfs.sh`), 0700 |
| `/etc/init.d/uc-pxx-step2` | the OpenRC service (`rootfs/step2/`), in the default runlevel: it starts `uc-pxx-step2 service` once per boot in the background, and a stop never ends it |
| `/etc/conf.d/uc-pxx-step2` | `UC_PXX_STEP2_PAYLOAD=` empty: the service asks nothing |
| `/etc/uc-pxx-step2/supervised` | the supervised marker (only a SUPERVISED step-2 build, `UC_PXX_SSH_ACCESS=keys`): the service never writes or counts down by itself |
| `/etc/tsx/step2-bootctl-inst` | says that this is a step-2 build, and which: `(supervised)` or `(end user)` |

An END-USER step-2 build (`UC_PXX_SSH_ACCESS=setup`: no ssh key) has no
`/etc/uc-pxx-step2` at all: its step 2 may start by itself (the AUTO-STEP2
countdown), and it installs only an end-user payload of its release.

The data tool of step 2 is `/usr/sbin/uc-pxx-data-migrate` of uc-pxx-board
(sha256 `9162c65d...`); the build stops without it. Such an image is for no
unit until the owner enters its lines in the safety rules.

### Packages of a private build (TEST ONLY)

`UC_PXX_DEV_APK_KEY=NAME.rsa.pub` (payload option `--dev-apk-key`) installs
uc-pxx packages that are not published yet from `TSX_APK_LOCAL`, signed by a
key of the build host. `mkrootfs.sh` trusts the key for the install only and
removes it from the image's `/etc/apk/keys`, so the panel trusts only the
project key. The image has `/etc/tsx/dev-apk-key` (the name and the sha256 of
the key), and `rootfs.sizes` says so. Never publish such an image.

## Board values

`rootfs/overlay/usr/local/lib/tsx/board.sh` holds the values and the small
functions that the shared scripts read. The main values:

| Name | Value |
|---|---|
| `TSX_FAMILY`, `TSX_APK_CATEGORY`, `TSX_PKG_PREFIX` | `uc-pxx` |
| `TSX_SOUND_CARD` | `UCP10` |
| `TSX_DISPLAY_DRM`, `TSX_RENDER_DRM` | `rockchip-drm`, `panfrost` (the driver names in `/sys/class/drm/card*/device/driver`) |
| `TSX_SERIAL_CONSOLE` | `ttyS2` |
| `TSX_MAC_SOURCE` | `cfg` |

`tsx-autoupdate` builds the package names `$TSX_PKG_PREFIX-board` and
`$TSX_PKG_PREFIX-kernel*`. This board sets `TSX_PKG_PREFIX=uc-pxx`. The
variable and the board hook need a tsx-linux-common that has them (see the
note in "Where the packages come from").

The functions `tsx_board_pre_update` and `tsx_board_post_update` are the
board hooks of `tsx-autoupdate`. The first runs `uc-pxx-arm-slot` before
`apk upgrade` changes the system. The second runs `uc-pxx-post-update` after
`apk upgrade` and before the restart, so a new kernel goes into `boot_a`
([boot-control.md](boot-control.md) "Kernel updates"). `TSX_POST_UPDATE_STEP`,
`tsx_board_post_update_meaning` and `tsx_board_update_status` give the text
of Home Assistant and of `tsx-autoupdate status`.

### Hardware facts and panel-board.d

`tsx-hw detect` runs at boot, from the common script of `tsx-config`. It
writes two files in `/run/tsx`:

- `hw.conf`, the facts of the panel. `tsx-config`, `tsx-setupd`, `tsx-bt`,
  `tsx-voice` and the ESPHome device read it.
- `panel-board.conf`, the board values. `/etc/tsx/panel-board.conf` is a link
  to it. The program builds it from `/etc/tsx/panel-board.d/default.conf`, then
  `UC-P10.conf` or `UC-P8.conf` (the model of the device tree), then
  `local.conf`. A key in a later file replaces the key of an earlier file.

| Key | Value | Source |
|---|---|---|
| `ORIENTATION_HW` | `landscape` | Fixed. The UC-P10 is a landscape device |
| `MIC`, `BT`, `WIFI` | `yes` | Fixed. Parts of the board |
| `CAMERA` | `no` | Fixed. The camera is not fitted |
| `LEDBAR` | `no` | Fixed. The USB-C port is a device port, so no LED bar can be attached |
| `PRESENCE` | `pir` or `no` | `pir` when an input device `gpio-keys` has the switch bit 11 (`SW_FRONT_PROXIMITY`). `pir` is a motion sensor: common shows the Presence sensor and no Distance sensor |
| `LIGHT` | `yes` or `no` | An IIO device named `jsa1212` |

`default.conf` holds the backlight range and the values of the light sensor.
The backlight has the 256 levels of the stock curve (`max_brightness` 255).
Level N gives the duty cycle `table[N]` of 255. The UC-P10 table runs 0, 5 ...
225, the UC-P8 table runs 0, 4 ... 168. The levels 1 to 5 of the UC-P10 all
give duty 5, and level 255 gives duty 225. The board values are levels, not
duty cycles: `BACKLIGHT_MAX=255`, `BACKLIGHT_MIN=16` (duty 14, about 5 percent,
the screen never looks off), `BRIGHTNESS_DAY=240` (the stock default level) and
`BRIGHTNESS_NIGHT=40` (duty 35). With more than 64 levels the slider of the
shared software uses a square scale. Nobody has tuned these values on the
glass.

`default.conf` also sets `KIOSK_SCALE=1.5`. The kiosk gives it to Chromium as
`--force-device-scale-factor`. At scale 1 the text on the 1200x1920 panel is
too small.

### MAC address

The MAC address of eth0 is in the `cfg` partition, in bytes 6 to 11. The
function `tsx_board_mac` reads exactly these six bytes with `dd`. It never
writes the partition and never copies it, because the partition also holds a
private key. An address is valid if it is not all zeros, not all ones, and a
globally administered unicast address.

### Model

The model comes from the compatible string of the device tree. The value
`crestron,uc-p10` gives UC-P10, and `crestron,uc-p8` gives UC-P8.

## Services

All services of this family start with `uc-pxx-`.

| Service | Runlevel | State |
|---|---|---|
| `uc-pxx-lvm` | boot | Done. Mounts `/data`: `userdata` (ext4 `tsxdata`) or the LVM data volume |
| `uc-pxx-clock` | boot | Keeps the boot clock at or after the clock floor, after `hwclock`. See "Clock" |
| `uc-pxx-watchdog` | boot | Done. Feeds `/dev/watchdog0` with the busybox watchdog |
| `uc-pxx-firmware` | boot | Copies the Wi-Fi and Bluetooth files from the vendor partition and starts their drivers again. See "Firmware" |
| `uc-pxx-switch` | boot | Sets the MAC address and starts the Ethernet switch. Not tested in this form |
| `uc-pxx-audio` | default | Done. Mixer defaults and volume |
| `uc-pxx-boot-ok` | default | Starts the boot-marking hook. See [boot-control.md](boot-control.md) |
| `uc-pxx-presence` | default | Done. Reads the PIR switch and writes the presence state. See "Presence" |
| `uc-pxx-loader-key` | sysinit | Volume down + Mute held for 3 s in the first 60 s of uptime: `uc-pxx-reboot loader` (the loader mode). It ends at 60 s. See [boot.md](boot.md) "The loader mode" |
| `uc-pxx-als` | default | Done. Reads the light sensor and feeds the automatic brightness. See "Ambient light" |
| `uc-pxx-leds` | default | The LED daemon, from the package `uc-pxx-leds`. It owns the four indicators and the RGB status LED, and shows the boot state. See [leds.md](leds.md) |

### Clock

The image uses the OpenRC service `hwclock` (UTC) in the boot runlevel, not
`swclock`. The RTC of the RK808 (`rtc0`) keeps the time over a reboot. It has
no backup battery, so after a power cut it reads a date in 2013. The kernel
does not copy the RTC to the system time (`RTC_HCTOSYS` is off), so only
`hwclock` reads it.

`uc-pxx-clock` runs after `hwclock`. The clock floor is the mtime of
`/var/lib/misc/openrc-shutdowntime`: the build time of the image, or a later
time that `tsx-savetime` (tsx-base) saved while NTP had the time. If the
system clock is before the floor, `uc-pxx-clock` sets it to the floor and
writes the RTC. It never sets the clock back. `uc-pxx-clock status` shows the
system clock, the RTC and the floor.

The chrony configuration of tsx-base has `rtcsync`. While chrony is in sync,
the kernel copies the system time to the RTC every 11 minutes. `hwclock`
writes the RTC at a clean shutdown. After `date -s` without NTP, run
`hwclock -w -u` to keep the time over a reboot. The image adds no NTP server.
chrony uses the servers of the DHCP lease and the pool.

### Write-back

`/etc/sysctl.d/uc-pxx-writeback.conf` sets `vm.dirty_expire_centisecs=500`
and `vm.dirty_writeback_centisecs=100` (defaults 3000 and 500). A PoE panel
loses its power without a shutdown. With the defaults, written data can stay
in RAM for up to 35 seconds. A new Home Assistant login in the Local Storage
of Chromium was lost this way. Now data reaches the eMMC after about 6
seconds.

### Ambient light

`uc-pxx-als` reads the JSA1213 through the mainline driver `jsa1212`. The
driver shows the sensor as the IIO device `jsa1212` with `in_illuminance_raw`
(counts, 0 to about 4000) and `in_illuminance_scale` (0.5).

The program turns the counts into lux: `lux = counts x in_illuminance_scale x
ALS_SCALE`. The range is 0 to about 2000 lux in steps of 0.5 lux. The unit
that we tested read 58 counts (29 lux) in a room, 1 count (0.5 lux) when
covered and 138 counts (69 lux) with a flashlight.

`ALS_SCALE` corrects for the front window. It is 1 in `panel-board.d/default.conf`
because nobody has measured the window. Measure a known light and set the
factor in `panel.conf` (`ALS_SCALE`) or in `local.conf`. The curve of the
automatic brightness has its top at `AUTO_BRIGHTNESS_LUX` (500 lux). It goes
from `BRIGHTNESS_NIGHT` to `BRIGHTNESS_DAY` on a log scale. Both values are
levels of the backlight, which has the levels 16 to 255.

The program writes the shared files of tsx-linux-common:

| File | Content | Read by |
|---|---|---|
| `/run/tsx/als.state` | `raw` (lux), `report` (lux with a deadband), `auto`, `scale`, `learned`, `counts` | `tsx-panelctl`, `tsx-mqtt`, `tsx_panel`, the overlay |
| `/run/tsx/als-level` | The backlight level, while `AUTO_BRIGHTNESS` is on | `tsx-idled` |

`AUTO_BRIGHTNESS` is on by default (user decision 2026-10-24). It stays on while `panel.conf` does not set it. `tsx-als auto
on|off` (the Home Assistant switch and the overlay call it) sets it and runs
`tsx-config apply`. The apply reloads `uc-pxx-als` (`TSX_CONFIG_RELOAD`).
`ALS_WATCH=1` in `default.conf` makes `tsx-idled` apply a new level at once.

The shared module `tsx_brightness.py` (package `tsx-base`) gives the
debounce of the light and the learning of the curve. Without it, the level
follows the light with no debounce.

### Presence

The PIR motion detector is the switch `SW_FRONT_PROXIMITY` (`EV_SW`, code 11)
of the input device `gpio-keys`. It is 1 while the detector sees motion and
holds the 1 for about 15 seconds after the last motion. The same device also
reports `SW_DOCK` (the handset hook) and `SW_CAMERA_LENS_COVER` (the camera
shutter). `uc-pxx-presence` reads only the switch with code 11.

The program asks for the state of the switch with the ioctl `EVIOCGSW` twice
per second. It does not wait for events, because `tsx-idled` grabs every
input device while the screen is blank. A grabbed device sends no events to
other programs, but it still answers the ioctl.

| State | Rule |
|---|---|
| `present on` | At once when the switch is 1. If `PRESENCE_WAKE` is not `off`, the program runs `tsx-blank off` |
| `present off` | After the switch was 0 for `PRESENCE_HOLD_S` seconds (default 30). The detector adds its own 15 seconds |

The file `/run/tsx/presence.state` has the lines `present`, `wake`, `hold_s`
and `motion`. It has no `distance` line, because a PIR has no distance.
`motion` is the switch without the hold. `tsx-panelctl`, `tsx-mqtt` and the
ESPHome device read `present`. `PRESENCE=pir` in `hw.conf` makes common hide
the Distance sensor, `PRESENCE_DISTANCE_MM` and `PRESENCE_MIN_MM`
([leds.md](leds.md) "Presence without a distance").

`tsx-idled` opens the same input device. By the code of `tsx-idled` (not
tested on the unit), every change of the switch counts as activity. So it wakes a blank screen and restarts the blank
timeout, whatever `PRESENCE_WAKE` says. The hook and the camera shutter do the
same.

### Firmware

The AP6256 module needs firmware that belongs to the vendor. The repository
and the images hold none. `uc-pxx-firmware` copies three files from the
vendor partition (mounted read-only) to `/lib/firmware/brcm`:

| Vendor file | Copy |
|---|---|
| `fw_bcm43456c5_ag.bin` | `brcmfmac43456-sdio.bin` |
| `nvram_ap6256_FCC.txt` | `brcmfmac43456-sdio.txt` |
| `BCM4345C5.hcd` | `BCM4345C5.hcd` |

The drivers `brcmfmac`, `hci_uart_bcm` and `cfg80211` are built into the
kernel. They probe from the initramfs, before the root file system is
mounted, so they never find the files at their probe. After the copy,
`uc-pxx-firmware boot` starts them again:

| Driver | What the program does |
|---|---|
| `cfg80211` | `iw reg reload` at each boot. It loads `/lib/firmware/regulatory.db` (package `wireless-regdb`) |
| `brcmfmac` | It binds each Broadcom SDIO function (vendor `0x02d0`) that has no driver, function 1 first. `brcmfmac` lets go of both functions when the firmware is missing. If the program copied a Wi-Fi file while `brcmfmac` was bound, it unbinds both first |
| `hci_uart_bcm` | It unbinds and binds the serdev device once per boot, if it copied the patch file in this run, or if the kernel log has `BCM: firmware Patch file not found` |

Each step waits up to 10 seconds for the interface (`wlan0`, `hci0`) and
logs the result. The service runs in the boot runlevel, before `networking`
and `bluetooth`.

Open points:

- Phase 1 reads them from `vendor_b`. Phase 2 has no vendor partition. The
  installer must save the files to `/data` first.
- The program always copies the FCC NVRAM file. It must choose by region.

### Switch

The GMAC connects to an RTL8364B switch. `uc-pxx-switch` sets the MAC address
of eth0 and runs `rtl8363-init` while eth0 is down. The tool is built from
`tools/rtl8363-init` and links with the Realtek switch SDK (GPL-2.0).

The tool talks to the kernel driver `realtek-rtl8364b-smi` (compatible
`realtek,rtl8364b-smi`). The driver makes the file `smi` of the MDIO device:

| Item | Path or text |
|---|---|
| Device file | `/sys/bus/mdio_bus/devices/stmmac-0:1d/smi` |
| Driver folder | `/sys/bus/mdio_bus/drivers/realtek-rtl8364b-smi/` |
| `dmesg` prefix | `realtek-rtl8364b-smi stmmac-0:1d` |

The device file does not depend on the driver name. The service and the tool
look in the driver folder (`*/smi`).

### Audio

`uc-pxx-audio` replaces `tsx-audio` of the xx70. `uc-pxx-audio init` sets the
mixer to the state of the stock firmware. `uc-pxx-audio volume N` sets the
speaker level in percent. The configuration is `/etc/tsx/audio.conf`. The
file `/etc/asound.conf` maps the default PCM devices ([hardware.md](hardware.md)).

### Watchdog

`uc-pxx-watchdog` runs the busybox watchdog on `/dev/watchdog0`. The service
reads the maximum timeout from sysfs and lowers a larger setting to it. The
settings are in `/etc/conf.d/uc-pxx-watchdog`.

### Keys

`/etc/tsx/buttons-board.conf` lists the six touch keys in their physical
order: `teams`, `headset`, `speaker`, `volume_down`, `volume_up` and `mic`
([hardware.md](hardware.md) has the table). The layout is verified with
evtest. The file has no LED setting. The LEDs next to the keys are status
indicators, and the package `uc-pxx-leds` owns them ([leds.md](leds.md)).
`tsx-buttons` reports `leds no` on this board.

## Tests

The tests run on a host and need no unit. The workflow `tests.yml` runs them.

| Test | Checks |
|---|---|
| `rootfs/tests/test-profiles.sh` | The package, service and image file lists of the profiles |
| `rootfs/tests/test-board.sh` | The board values, the two board hooks, the MAC address, the model, the key codes and the absence of LED settings |
| `rootfs/tests/test-post-update.sh` | `uc-pxx-post-update` with stubs: the file check, the arm, the write and the A/B check, and the status for each case |
| `rootfs/tests/test-autoupdate-hooks.sh` | The board hooks with the real `tsx-autoupdate` of tsx-linux-common (`TSX_COMMON`), the real `uc-pxx-post-update` and stubs: the order arm, upgrade, arm, write, check, restart, no restart after a failed write, the repair of a hold, the lock |
| `rootfs/tests/test-hw.sh` | `tsx-hw` with a made-up `/sys`: the facts and the layers of `panel-board.d` |
| `rootfs/tests/test-als.sh` | `uc-pxx-als` and `tsx-als` with a made-up IIO device: counts to lux, the files, the backlight range, a reload |
| `rootfs/tests/test-loader-key.sh` | The loader mode keys: `uc-pxx-loader-key` (boot window, hold time, `--rescue`), the check in `/init`, the device tree node |
| `rootfs/tests/test-reboot.sh` | `uc-pxx-reboot loader` and `fastboot`: the clean path through init, `--pending`, the direct path of `/init`, the inittab lines |
| `rootfs/tests/test-rescue.sh` | The rescue system: the screen, the console font, the login, the build file |
| `rootfs/tests/test-install-rootfs.sh` | `uc-pxx-install-rootfs` against a made-up `/sys` and `/dev` |
| `rootfs/tests/test-presence.sh` | `uc-pxx-presence` with a made-up input device: the find of the switch, the states, the wake call, a reload |
| `rootfs/tests/test-audio.sh` | `uc-pxx-audio` with a stub `amixer` |
| `rootfs/tests/test-firmware.sh` | `uc-pxx-firmware` with a made-up vendor folder and a made-up `/sys` |
| `rootfs/tests/test-clock.sh` | `uc-pxx-clock` with stubs for `date` and `hwclock`, and the write-back sysctl |
| `rootfs/tests/test-esphome-plugin.sh` | The board plugin `uc-pxx.py` (the switches) against `tsx_panel` of tsx-linux-common |
| `packages/uc-pxx-leds/tests/test-*.sh` | The LED package: the file list, the daemon, the command and the ESPHome plugin (see [leds.md](leds.md)) |
| `rootfs/tests/test-switch.sh` | `uc-pxx-switch` with stub tools |
| `rootfs/tests/test-watchdog.sh` | The timeout checks of `uc-pxx-watchdog` |
| `rootfs/tests/test-kernel-pins.sh` | `rootfs/check-kernel-pins.sh` |

## TODO

- Tune the backlight levels and `ALS_SCALE` in `panel-board.d/default.conf` on
  the glass.
- A data volume check for the first boot (`tsx-data` of common).
- Chromium flags for panfrost (`TSX_BROWSER_GL_FLAGS`).
- The Bluetooth proxy default (`TSX_BT_PROXY_DEFAULT` is `off` until tested).
