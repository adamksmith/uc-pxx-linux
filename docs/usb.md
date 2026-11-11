# The USB interface of a mainline build

Every both-slot mainline build (the normal and the STEP-2 payload) has a USB
gadget on the USB-C port (owner decisions 2026-11-11; uc-pxx-installer
mainline-rc-4). It is the vendor interface (WebUSB, 1d6b:0105 for development,
interface ff/50/01) of `uc-pxx-xfer`, the program of uc-pxx-installer.

| File | What |
|---|---|
| `/usr/libexec/uc-pxx-xfer/uc-pxx-xfer` | the program (root, 0755; pinned by `XFER_SHA256` in `rootfs/mkrootfs.sh` and by the installer's both-slot gate) |
| `/etc/init.d/uc-pxx-usb` | the OpenRC service (default runlevel, `supervise-daemon`): `uc-pxx-xfer usb` |
| `/etc/conf.d/uc-pxx-usb` | the USB network setting, `UC_PXX_USB_NET=off` |
| `/usr/share/uc-pxx-usb/finish.json` | this slot's pinned finish set (see below) |
| `/etc/ssh/sshd_config.d/uc-pxx-usb.conf` | ssh by key only on the USB network address 10.99.0.2 |
| user and group `uc-pxx-xfer` (990) | the receiver's user: no shell, no home, no other group |

What a computer on the cable can do:

- **Always:** read the status (HELLO / STATUS): the model, the slot, the build
  token and the step of the mainline install. Never a serial number, a MAC
  address or a key.
- **In a STEP-2 build while step 2 waits for its payload:** the step-2 service
  stops `uc-pxx-usb`, receives the normal payload into RAM (only a payload
  whose manifest the step-2 gate pins), seals it and asks on the panel. Then
  `uc-pxx-usb` comes back.
- **In a normal build that has no done record of step 2:** send the finish set
  of step 2: exactly the two files that `finish.json` names by size and sha256
  (`uc-pxx-step2-finish` and `uc-pxx-bootctl-inst` r2), with `finish.json`
  first. The unit checks both files again as root, copies them into
  `/run/uc-pxx-finish` (RAM) and runs `uc-pxx-step2-finish finish-service` from
  there once per boot. That program does nothing on a slot that is not an
  unfinished step-2 target. Nothing is installed.

The receiver runs as the user `uc-pxx-xfer` with no eMMC code; the root side
writes only configfs, its mounts and its files in `/run`.

**The USB network** (`UC_PXX_USB_NET=on`, for supervised or development units
only): an NCM function after the vendor interface; the unit is 10.99.0.2/24, the
computer 10.99.0.1 (set by hand). ssh there takes a key only
(`/root/.ssh/authorized_keys`). Every service of the unit's LAN side is then
also reachable from the computer on the cable. Set it with
`rc-service uc-pxx-usb restart` after the change. OFF by default.

There is never a serial console (ACM) or a mass-storage function on this port.
