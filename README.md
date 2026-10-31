# TWRP for Famue BF61 (MT6762, k62v1_64_bsp)

TeamWin Recovery Project 12.1 device tree, built with
[minimal-manifest-twrp](https://github.com/minimal-manifest-twrp/platform_manifest_twrp_aosp)
on GitHub Actions.

## Device

| Item | Value |
| --- | --- |
| Model | Famue BF61 (4-inch Android media player) |
| SoC | MediaTek MT6762 (`ro.board.platform=mt6765` BSP tree) |
| Kernel | 4.19.191, prebuilt from stock boot_a.img |
| Boot image | header v2, pagesize 2048, kernel@0x40080000, ramdisk@0x51b00000, tags@0x47808000 |
| Partitions | A/B (slot A active), dynamic partitions, no dedicated recovery |
| Encryption | FBE v2 `aes-256-xts:aes-256-cts:v2` + metadata encryption (`md_udc`), inlinecrypt |
| Keymaster | HIDL 4.1 (`/vendor/bin/hw/android.hardware.keymaster@4.1-service`) |
| Gatekeeper | HIDL 1.0 |
| Display | 480x800, portrait |

## Building

```bash
repo init --depth=1 -u https://github.com/minimal-manifest-twrp/platform_manifest_twrp_aosp.git -b twrp-12.1
repo sync -c -j$(nproc)
git clone https://github.com/zhuzhuzihan/android_device_famue_bf61 device/famue/bf61
source build/envsetup.sh
lunch twrp_bf61-eng
mka bootimage -j$(nproc)
```

Output: `out/target/product/bf61/boot.img` (recovery merged into the boot
image via `BOARD_USES_RECOVERY_AS_BOOT`) — flash to the **boot** partition
(`fastboot flash boot boot.img`). There is no dedicated recovery partition
on this device. The B-slot images are empty; do not boot from slot B.

## CI

GitHub Actions workflow `.github/workflows/build.yml` builds on every push and
on manual dispatch; `boot.img` (recovery merged) is uploaded as an artifact.

## Backups

`bf61_backup/` (local, not committed): stock boot_a/b, vendor_boot_a/b,
dtbo_a/b, vbmeta images dumped via adb root.

## Acknowledgments

- minimal-manifest-twrp team
- OrangeFoxRecovery blossom tree (MT6765-family reference values)
