# Mainline payload

The mainline payload is the input of the installer for a mainline install on
a UC-P10 (uc-pxx-installer, mainline mode). It holds the boot image of the
kernel without the vendor resource, the root file system and a manifest.
`tools/mainline-payload/build.sh` makes it on a build host. This page tells
the contract (version 1) and how to build the payload.

Nothing on this page touches a unit. The installer does all writes, with its
own checks and reviews. Read [boot.md](boot.md) and
[boot-control.md](boot-control.md) first.

## Contract v1

The P10-INSTALL drive holds a folder `uc-pxx-mainline/` with three files:

| File | Content |
|---|---|
| `manifest.json` | The manifest (below) |
| `boot-template.img` | An Android boot image of header version 0, made by `kernel/mkimage.sh` with an empty resource (the `second` part is empty). The header name is the build token. The device tree in the shim has `uc-pxx.id=<token>` in `/chosen/bootargs`. The kernel part is the shim (stub, device tree, Linux Image) of the pinned kernel |
| `rootfs.ext4` | The root file system for `system_a`: ext4, label `tsxroot`, the size a multiple of 512 bytes. The initramfs grows it to fill the partition on the first boot |

`manifest.json` (all sha256 values in lower-case hex, all sizes in bytes):

```json
{
  "schema": 1,
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
  "vbmeta_boot_cap": 38029312
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
- `vbmeta_boot_cap` is the `image_size` of the boot hash descriptor of the
  signed 1.0.0.94 userdebug vbmeta. libavb loads only this many bytes of
  `boot_a`, so a larger image is cut off.
- `requires_bootchain` is the boot chain of 1.0.0.94 userdebug that the
  mainline slot needs.
- The consumer refuses unknown keys, a schema other than 1 and a model other
  than `UC-P10`.

The payload never holds a vendor file. The template has no resource. The
assembled image is computed on the build host only for its sha256 and size,
and then deleted.

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
tools/mainline-payload/build.sh build --snapshot SNAP --resource RESOURCE --out OUT \
    --apk-url https://tsx-aports.unexceptional.net/testing

# 3. a reproduction: the same bytes from the same inputs, in another folder
tools/mainline-payload/build.sh build --snapshot SNAP --resource RESOURCE --out OUT2 --inputs OUT/inputs.txt
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
- `RESOURCE` is the stock resource (sha256 `290ef405...`). It is a vendor file
  and stays on the build host.
- `--authorized-keys FILE` bakes ssh keys for root into the rootfs (the
  release workflow uses the secret `TSX_AUTHORIZED_KEYS`). Without it the
  image has no ssh key and a locked root password ([rootfs.md](rootfs.md)
  "Root login").

The outputs in `OUT`:

| File | Content |
|---|---|
| `uc-pxx-mainline/` | The payload folder. When the assembled image is larger than `vbmeta_boot_cap`, the folder is `uc-pxx-mainline.OVER-CAP/` and the exit status is 3: never give such a folder to the installer |
| `inputs.txt` | The inputs of the build (the format is in the header of `build.sh`) |
| `build-info.txt` | Sizes, the cap verdict, the drive verdict, the initramfs facts |
| `rootfs.manifest`, `rootfs.sizes` | The package versions and sizes of the rootfs |
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

- `boot_assembled` must be at most `vbmeta_boot_cap` (38,029,312 bytes) for
  the signed 1.0.0.94 vbmeta. `build-info.txt` gives the margin or the excess.
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

So that build gives `uc-pxx-mainline.OVER-CAP/`. The initramfs is only about
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
