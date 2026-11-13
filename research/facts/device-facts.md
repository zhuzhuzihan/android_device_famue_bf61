# Famue BF61 — authoritative device facts extracted from stock images

Scope: everything below is derived **only** from the read-only stock dumps in `/sdcard/bf61_backup/` and the
already-unpacked trees in `/root/work/bf61/`. Every claim carries the evidence that produced it and a
confidence tag:

- **[V]** verified — read directly from bytes on disk, reproducible with the command shown.
- **[I]** inferred — reasoned from indirect evidence; the competing explanation is stated when one exists.

Reproduce every number in one shot:

```bash
python3 /root/android_device_famue_bf61/research/facts/tools/bf61_facts.py    # read-only, prints all sections
```

Inputs and their sha256 (full dumps, partition-sized):

| file | size | sha256 |
| --- | --- | --- |
| `boot_a.img` | 33554432 | `91a846af6bc0328091e9a3477cd9cfad4b64aa5192674c3219ec399b14f5924e` |
| `boot_b.img` | 33554432 | `83ee47245398adee79bd9c0a8bc57b821e92aba10f5f9ade8a5d1fae4d8c4302` (all zero) **[V]** |
| `boot_working.img` (stock+Magisk) | 33554432 | `f954cdf27f280b37a4e5f916b0086fbf290e3992d5cba4b53849fb6b5973ba37` |
| `dtbo_a.img` | 8388608 | `9f792c2f1c5a2a70010d2887c254793324231b21a842a09ac2fb29c0ec2399f2` |
| `dtbo_b.img` | 8388608 | all zero **[V]** |
| `vbmeta_a.img` | 8388608 | AVB0, flags `0x3` **[V]** |
| `vbmeta_b.img`, `vbmeta_system_b.img`, `vbmeta_vendor_b.img` | — | all zero **[V]** |

---

## 1. Boot image header (v2)

`struct boot_img_hdr_v2`, little-endian, parsed at these offsets of `boot_a.img`:

| field | offset | value | note |
| --- | --- | --- | --- |
| `magic` | 0x000 | `ANDROID!` | **[V]** |
| `kernel_size` | 0x008 | `0x00aef4ef` = 11465967 | 5599 pages of 2048 **[V]** |
| `kernel_addr` | 0x00c | `0x40080000` | = base + 0x8000 **[V]** |
| `ramdisk_size` | 0x010 | `0x00ae74a4` = 11433124 | 5583 pages **[V]** |
| `ramdisk_addr` | 0x014 | `0x51b00000` | = base + 0x11a88000 **[V]** |
| `second_size` | 0x018 | `0` | no second stage **[V]** |
| `second_addr` | 0x01c | `0` | *not* base+offset — see §8 **[V]** |
| `tags_addr` | 0x020 | `0x47880000` | = base + 0x07808000 **[V]** |
| `page_size` | 0x024 | `2048` (`0x800`) | **[V]** |
| `header_version` | 0x028 | `2` | **[V]** |
| `os_version` | 0x02c | `0x18000183` | decode `(ver,patch,year,month) = (12, 0, 24, 3)` → `12.0.0 / 2024-03` **[V]** |
| `name[16]` | 0x030 | 16 × `00` | empty board name **[V]** |
| `cmdline[512]` | 0x040 | `bootopt=64S3,32N2,64N2 buildvariant=user androidboot.selinux=permissive` | 68 bytes + NUL **[V]** |
| `id[32]` | 0x240 | `47847bb14511df1b22dffae0a04d985043db5ae7` + 12 × `00` | sha1, see below **[V]** |
| `extra_cmdline[1024]` | 0x260 | all `00` | empty **[V]** |
| `recovery_dtbo_size` | 0x660 | `0` | **[V]** |
| `recovery_dtbo_offset` | 0x664 | `0` | **[V]** |
| `header_size` | 0x66c | `1660` (`0x67c`) | exactly `sizeof(boot_img_hdr_v2)` **[V]** |
| `dtb_size` | 0x670 | `0x18d61` = 101729 | **[V]** |
| `dtb_addr` | 0x674 | `0x47880000` | = base + 0x07808000, same as `tags_addr` **[V]** |

Physical layout (**[V]**, computed from the sizes above):

```
0x000000  header (1660 B) + zero pad to page
0x000800  kernel      11465967 B   (5599 pages)
0x0af0000 ramdisk     11433124 B   (5583 pages)
0x15d7800 second      0 B          (0 pages)
0x15d7800 dtb         101729 B     ← same offset as second, because second_size == 0
0x15f0561 end of dtb → 0x15f0800 (page-aligned) is the AVB-hashed image end
0x15f1000 AVB0 vbmeta blob (1664 B), 0x1ffffc0 AVBf footer, rest zero to 32 MiB
```

Derived base: `kernel_addr − 0x8000 = 0x40078000`, and every offset reproduces exactly:

```
base           0x40078000
kernel_offset  0x00008000   -> 0x40080000  ✓
ramdisk_offset 0x11a88000   -> 0x51b00000  ✓
tags_offset    0x07808000   -> 0x47880000  ✓
dtb_offset     0x07808000   -> 0x47880000  ✓
```

Kernel / ramdisk compression — **both gzip**, not lz4 **[V]**:

```
kernel  @0x800      starts 1f8b080000000000 ; gzip.decompress -> 28386976 bytes, tail 00000000
ramdisk @0xaf0000   starts 1f8b080000000000 ; gzip.decompress -> 27294720 bytes
```

So the build must keep `BOARD_RAMDISK_USE_LZ4` unset/`false` (AOSP emits `MINIGZIP`), otherwise the repacked
ramdisk stops matching the stock compression and `magiskboot`/TWRP repack paths change behaviour.

`id` is a **genuine AOSP mkbootimg sha1**, i.e. the stock image came out of stock `mkbootimg`, not an
MTK-private packer **[V]**. Recomputation with AOSP 12.1 order
(`sha1(kernel ‖ ksize ‖ ramdisk ‖ rsize ‖ second ‖ recovery_dtbo ‖ dtb ‖ dsize)`, `update_sha` writing
`pack('I',0)` for absent parts) gives `47847bb14511df1b22dffae0a04d985043db5ae7` = the header field exactly.
`boot_working.img` recomputes the same way (`74e57093212c…`), so the Magisk-patched image is also a clean
`mkbootimg` output.

Byte-identity with the repo prebuilts **[V]**:

```
stock/boot_a.kernel  0819ced7744523e98a6e88f495a82d78057d766fb72436d125f15e39e7954014
prebuilt/kernel      0819ced7744523e98a6e88f495a82d78057d766fb72436d125f15e39e7954014   IDENTICAL
stock/boot_a.dtb     02b1c805351a56f8d088b35d5f14f2fccf29df3ac5a61fe30f5778334bada1a8
prebuilt/dtb.img     02b1c805351a56f8d088b35d5f14f2fccf29df3ac5a61fe30f5778334bada1a8   IDENTICAL
```

Kernel version string **[V]**: `Linux version 4.19.191 (nobody@android-build) … #4 SMP PREEMPT Wed May 21
19:21:34 CST 2025` (Android clang 11.0.1 / LLD 11.0.1). The repo README's "4.19.191" claim is correct.

`boot_b.img` is **33554432 / 33554432 zero bytes** — slot B holds no boot image **[V]**.

Magisk working image differs from stock only in the ramdisk **[V]**:
`ramdisk_size 0xb257f7` (11687927) vs `0xae74a4`; kernel `0x00aef4ef` and dtb `0x18d61` identical.

---

## 2. DTB section inside `boot_a.img`

The `dtb` slot is **not a bare FDT** — it is an MTK/`mkdtimg` **dt_table container** **[V]**:

```
offset 0x15d7800, length 101729
d7 b7 ab 1e | total_size=101729 header_size=32 entry_size=32 entry_count=1
            | entries_offset=32 page_size=2048 version=0
entry[0] @ +32: dt_size=101665 dt_offset=64 id=0 rev=0 custom[16]=00…
FDT magic d0 0d fe ed at +64, FDT totalsize = 101665
```

Consequences: `entry.dt_offset + entry.dt_size == total_size`, `id=rev=0`, one entry. This is what
`mkdtimg create --page_size 2048` produces, and it is passed to `mkbootimg --dtb` **verbatim** — the build
tree must never treat `prebuilt/dtb.img` as a plain FDT (see §8 and the Appendix).

Parsed FDT (the Lead's `tools/fdt.py`, 593 nodes):

| item | value | conf |
| --- | --- | --- |
| root `model` | `MT6765` | **[V]** |
| root `compatible` | `mediatek,MT6765` | **[V]** |
| `/chosen` `bootargs` | `console=tty0 console=ttyS0,921600n1 vmalloc=400M slub_debug=OFZPU page_owner=on swiotlb=noforce androidboot.hardware=mt6765 maxcpus=8 loop.max_part=7 firmware_class.path=/vendor/firmware` | **[V]** |

That `bootargs` line is the single most load-bearing string in the DTB, because
`androidboot.hardware=mt6765` is what defines `ro.hardware` on this device (see §6).

Node inventory relevant to recovery:

| node | compatible | meaning | conf |
| --- | --- | --- | --- |
| `/touch` | `mediatek,cap_touch` | MTK tpd wrapper; **no** `tpd-resolution`, no reset GPIO — everything else is added by dtbo | **[V]** |
| `/i2c0@11007000` … `/i2c9` | `mediatek,i2c` | 8 real buses + 3 skeleton nodes (`i2c7/8/9` have no compatible) | **[V]** |
| `/usb0@11200000` | `mediatek,mt6765-usb20` | **MUSB** dual-role controller (see §6, `sys.usb.controller=musb-hdrc`) | **[V]** |
| `/usb-phy@11210000` | `mediatek,generic-tphy-v1` | USB2 PHY | **[V]** |
| `/extcon_usb` | `mediatek,extcon-usb` | `usb = "/usb0@11200000"`, `u2phy0 = "/usb-phy@11210000"` | **[V]** |
| `/msdc@11230000` | `mediatek,msdc` | msdc0 = **eMMC**, `bus-width = <8>`, HS400/HS200 pinctrl states | **[V]** |
| `/msdc@11240000` | `mediatek,msdc` | msdc1 = SD card, `bus-width = <4>`, `/msdc1_ins@0` card-detect | **[V]** |
| `/msdc@11250000`, `/msdc@11260000` | `mediatek,msdc2`, `msdc3` | SDIO (wifi/BT), unused here | **[V]** |
| `/mtkfb@0` | `mediatek,mtkfb` | **only** `compatible` + `phandle` — no geometry | **[V]** |
| `/dsi0@14014000` | `mediatek,dsi0` | DSI host; no panel node, no timing | **[V]** |

There is **no `/ufs*` node anywhere** in the DTB, and msdc0 is 8-bit wide with HS400 pinctrl: storage is
**eMMC**, not UFS **[V]**. This matters because `ro.vendor.mtk_ufs_support`-style symlink games exist in the
stock rc files (eMMC boot region exposed as `/dev/block/sd[a-c]`, §6).

### Display: resolution and rotation (extra priority)

Panel geometry is **not** in the DTB, the DTBO, or `prop.default` — it is selected by LK from the kernel's
LCM driver list, so it has to be inferred **[I]**:

| evidence | value | conf |
| --- | --- | --- |
| kernel (`Image`, `strings -n 8`) primary-path LCM identity | `…:lanse pear0726 r63306_hd720_dsi_vdo_xiapu_4p3  boe lcm adc_vol is %d` — the only `hd720` LCM identity in the whole 28 MB image, sitting in the main DISP/CMDQ region next to ODM-customised code (`lanse`, `pear0726`, ADC volume hack) | **[V]** string, **[I]** meaning |
| other LCM-ish strings | `st7701s_boe` / `Dst7701` appear inside the **`[EXTD]`** (external-display) block, i.e. HDCP/ESD helpers for the external path, not the primary panel | **[V]** |
| `ro.sf.lcd_density` (`prop.default:143`) | `210` | **[V]** |
| `ro.surface_flinger.primary_display_orientation` | `ORIENTATION_0` | **[V]** |
| stock recovery resource set | `res/images/loop00000.png` = **200×200** = the AOSP **mdpi** bucket (measured in `/root/twrp-research/recovery-12.1/res-*`: mdpi 200, hdpi 300, xhdpi 400, xxhdpi 600, xxxhdpi 800). *Weak* counter-evidence only — MTK builds commonly leave recovery on the default mdpi assets regardless of panel | **[V]** measurement, **[I]** meaning |
| public listing for this model | "Famue BF61 **4 Inch**" Android media player (matches the `4p3` = 4.3″ suffix in the LCM name) | **[I]** |

Conclusion: **720×1280 (HD720), portrait, natural orientation 0** **[I, medium-high]**.
The decisive point is that the kernel carries exactly **one** primary-path LCM driver identity and MTK makes a
mismatch between LK's reported LCM name and the kernel's driver list a hard boot error
(`[DISP][%s #%d]ERROR:FATAL ERROR!!!LCM Driver defined in kernel(%s) is different with LK(%s)`, present in
`Image`), so this kernel can only boot a `hd720` panel.

Counter-evidence, stated honestly: density `210` fits a 480×800 panel at 4.3″ (217 dpi) just as well as a
720×1280 panel at 7″ (210 dpi); the product is marketed as "4 inch"; the stock recovery assets are the mdpi
set; and the repo's `README.md` currently asserts "480x800, portrait" with no evidence file behind it. Nothing
in the backup set can settle it — the DTB has no geometry and there is no `/vendor`/`lk` dump.
Settle it in one command on first boot:

```bash
adb shell cat /sys/class/graphics/fb0/virtual_size     # prints W,H of the active mode
adb shell dumpsys SurfaceFlinger | grep -i "display\|density"
```

Recommended `TW_THEME` and why **[I, medium-high]**:

```make
TW_THEME := portrait_hdpi          # for the 720x1280 panel that the kernel LCM name implies
# fallback if `cat /sys/class/graphics/fb0/virtual_size` reports 480x800:
# TW_THEME := portrait_mdpi
```

TWRP 12.1 ships only these themes, with the resolutions declared in their `ui.xml`
(`/root/twrp-research/recovery-12.1/gui/theme/*/ui.xml`, measured): `portrait_mdpi` 480×800, `portrait_hdpi`
**1080×1920**, `landscape_mdpi` 800×480, `landscape_hdpi` 1920×1200, `watch_mdpi` 320×320.
`gui/pages.cpp:875-905` reads `<resolution>` and calls `set_scale_values(fb_w/width, fb_h/height)`, so the
theme is scaled to the framebuffer rather than mis-drawn. On a 720×1280 panel:

- `portrait_hdpi` (1080×1920, 9:16) scales by a **uniform 0.667** → pixel-perfect, no distortion.
- `portrait_mdpi` (480×800, 3:5) scales 1.50 horizontally but 1.60 vertically → 6 % vertical stretch and
  slightly misplaced touch targets. That is what the repo currently selects.

Both choices boot and are merely ~6 % off if the panel guess is wrong, so the cheap move is: build once with
`portrait_hdpi`, and if `fb0/virtual_size` disagrees, flip the one line from the TWRP terminal and rebuild.
No `TW_ROTATION` / `TW_ORIENTATION` override is justified either way: `primary_display_orientation=ORIENTATION_0`
and the LCM is a portrait `_dsi_vdo` panel, so leave rotation at default (0).

---

## 3. DTBO partition (`dtbo_a.img`)

Header **[V]**:

```
magic d7b7ab1e | total_size=34051 header_size=32 entry_size=32 entry_count=1
                | entries_offset=32 page_size=2048 version=0
entry[0] @32: dt_size=33987 dt_offset=64 id=0 rev=0 custom[16]=00…   (FDT d00dfeed at +64)
```

Partition layout (8 MiB) **[V]**:

```
0x000000  dt_table             34051 B   (total_size)
0x008503  MTK certificate blob  3741 B   ASCII "cert1" visible at +0x08; ends at 0x0093A0 = 37792
0x0093A0  zero pad to 0x00A000
0x00A000  AVB0 vbmeta blob       640 B
0x7FFFC0  AVBf footer: v1.0 original_image_size=**37792** vbmeta_offset=0xA000 vbmeta_size=640
```

So "dtbo image size" per AVB is 37792 = dt_table (34051) + MTK `cert1` trailer (3741); the trailer is an MTK
signature, **not** a second table — this is why AVB's `original_image_size` and `dt_table.total_size` differ
(no inconsistency, nothing was re-flashed) **[V]**.

Fragments / targets (57 fragments, resolved through `/__fixups__`) — display, touch and power only:

| fragment | target label | content |
| --- | --- | --- |
| `@1` | `odm` | `led@6` `mediatek,lcd-backlight` → **`/sys/class/leds/lcd-backlight/brightness`**, plus `led@0..5` (red/green/blue/jogball/keyboard/button) and `vibrator@0` **[V]** |
| `@18` | `mtkfb` | FB/display properties (no geometry) **[V]** |
| `@19` | `pio` | `lcm_rst_out0_gpio` / `lcm_rst_out1_gpio` → symbols `mtkfb_pins_lcm_reset0/1` (LCM reset pinctrl) **[V]** |
| `@23` | `i2c0` | `cap_touch@5d`: `compatible="mediatek,cap_touch"`, `reg=<0x5d>`, `status="okay"` → **touch on i2c0 addr 0x5d** **[V]** |
| `@35`,`@49`,`@55` | `touch` | touch `interrupt-parent`, `vtouch-supply` (PMIC LDO28) **[V]** |
| `@56` | `pio` | `eint1touch@0`, `rstoutput0/1`, `eint0default`, `eintoutput0/1` → touch EINT + reset pins **[V]** |
| `@10`,`@24` | `i2c1` | `gsensor@68`, `msa311@62` **[V]** |
| `@2/26`,`@3/29`,`@25`,`@27`,`@28` | `i2c3/6/2/4/5` | ext bucks, camera main/sub, subpmic **[V]** |

No panel timing, no resolution, no rotation node exists in the overlay **[V]** — consistent with §2.

Touch controller identity **[V]**: kernel prints
`drivers/input/touchscreen/axs15260_mtk_touch/tpd_control.c` and `mediatek,cap_touch`, so the TP IC is
**AXS15260** on i2c0@0x5d. Its reset/EINT lines are the dtbo pinctrl nodes above; `TW_IGNORE_MT_POSITION_0`
etc. should only be added if first-boot touch reports garbage coordinates.

### Trimmed artifact

Written to `research/artifacts/dtbo.img`, exactly `total_size` bytes **[V]**:

```
size     34051
sha256   061c71cab6ee955307fc8ff7b52abf4b2a5b62aef63abc63c0b92a33f324790a
reparse  ok: magic d7b7ab1e, total=34051, 1 entry, dt_size 33987 @64, FDT d00dfeed totalsize 33987,
         dt_offset+dt_size == total_size == file size
```

**Repo note [V]**: `prebuilt/dtbo.img` is `9f792c2f…` = byte-identical to the *full 8 MiB partition dump*
(dt_table + MTK cert + AVB vbmeta + AVB footer). That is the correct artefact to ship for flashing
(`fastboot flash dtbo` / `BOARD_PREBUILT_DTBOIMAGE` with `BOARD_DTBOIMG_PARTITION_SIZE := 8388608`): it
restores the partition byte-for-byte and keeps the vendor's `cert1` trailer for the (currently unlocked)
MTK secure-boot path. The 34051-byte file is the canonical *upstream-format* image, useful for `mkdtimg`
tooling/diffs, but flashing it silently drops the `cert1` trailer and the AVB footer — do not swap it in
without testing.

---

## 4. `vendor_boot_a.img` / `vendor_boot_b.img`

**[V]** Both are **67108864 bytes of `0x00`**, no `VNDRBOOT` magic, no header version, no ramdisk:

```
vendor_boot_a.img size=67108864 first8=0000000000000000 all_zero=True
vendor_boot_b.img size=67108864 first8=0000000000000000 all_zero=True
```

Implications for BoardConfig:

- The build must **not** produce a vendor_boot image: keep `BOARD_BOOT_HEADER_VERSION < 3` (i.e. `2`).
  `build/make/core/board_config.mk:420-425` turns `BUILDING_VENDOR_BOOT_IMAGE` on only for
  `BOARD_BOOT_HEADER_VERSION >= 3`; with `>= 3` the `--dtb` is moved out of `boot.img`
  (`core/Makefile:894-909`) into an image this device never boots from → **black screen, no recovery**.
- Do **not** set `BOARD_MOVE_RECOVERY_RESOURCES_TO_VENDOR_BOOT` (requires `BUILDING_VENDOR_BOOT_IMAGE`,
  `board_config.mk:902`) and do **not** set `BOARD_VENDOR_RAMDISK_FRAGMENTS`/`..._FRAGMENTS_4`
  (`>= 4` required, `board_config.mk:910`).
- `mka recoveryimage` yields nothing usable here; the target is **`mka bootimage`**
  (`BOARD_USES_RECOVERY_AS_BOOT := true` makes `INSTALLED_RECOVERYIMAGE_TARGET` empty,
  `core/Makefile:168`).
- `BOARD_VENDOR_BOOTIMAGE_PARTITION_SIZE := 67108864` is harmless but dead weight once no vendor_boot is
  built; keep it only as documentation of the partition size.

---

## 5. Stock fstab (`/root/work/bf61/rd_stock/first_stage_ramdisk/fstab.mt6762`)

The same file is installed three times in the stock ramdisk — all sha256 `cf5bb9de…` **[V]**:
`first_stage_ramdisk/fstab.mt6762`, `first_stage_ramdisk/fstab.mt6765`, `system/etc/recovery.fstab`.
The header comment proves the source: `vendor/mediatek/proprietary/hardware/fstab/mt6765/fstab.in.mt6765`
(i.e. generated from the **mt6765** BSP fstab and copied under both hardware names).

Normalised table (order preserved, blank lines collapsed):

| # | block device | mount point | type | options | flags | conf |
| --- | --- | --- | --- | --- | --- | --- |
| 1 | `system` (logical) | `/system` | ext4 | ro | `wait,avb=vbmeta_system,logical,first_stage_mount,avb_keys=/avb/q-gsi.avbpubkey:/avb/r-gsi.avbpubkey:/avb/s-gsi.avbpubkey,slotselect` | **[V]** |
| 2 | `system_ext` (logical) | `/system_ext` | ext4 | ro | same as #1 | **[V]** |
| 3 | `vendor` (logical) | `/vendor` | ext4 | ro | `wait,avb,logical,first_stage_mount,slotselect` | **[V]** |
| 4 | `product` (logical) | `/product` | ext4 | ro | `wait,avb,logical,first_stage_mount,slotselect` | **[V]** |
| 5 | `/dev/block/by-name/md_udc` | `/metadata` | ext4 | `noatime,nosuid,nodev,discard` | `wait,check,formattable,first_stage_mount` | **[V]** |
| 6 | `/dev/block/by-name/userdata` | `/data` | ext4 | `noatime,nosuid,nodev,noauto_da_alloc,errors=panic,inlinecrypt` | `latemount,wait,check,quota,reservedsize=128M,formattable,resize,,checkpoint=block,fileencryption=aes-256-xts:aes-256-cts:v2,keydirectory=/metadata/vold/metadata_encryption` | **[V]** |
| 7 | `/dev/block/by-name/protect1` | `/mnt/vendor/protect_f` | ext4 | `noatime,nosuid,nodev,noauto_da_alloc,commit=1,nodelalloc` | `wait,check,formattable` | **[V]** |
| 8 | `/dev/block/by-name/protect2` | `/mnt/vendor/protect_s` | ext4 | idem | `wait,check,formattable` | **[V]** |
| 9 | `/dev/block/by-name/nvdata` | `/mnt/vendor/nvdata` | ext4 | idem | `wait,check,formattable` | **[V]** |
| 10 | `/dev/block/by-name/nvcfg` | `/mnt/vendor/nvcfg` | ext4 | idem | `wait,check,formattable` | **[V]** |
| 11 | `/devices/platform/externdevice*` | auto | auto | defaults | `voldmanaged=sdcard1:auto,encryptable=userdata` | **[V]** |
| 12 | `/devices/platform/mt_usb*` | auto | vfat | defaults | `voldmanaged=usbotg:auto` | **[V]** |
| 13 | `/dev/block/by-name/frp` | **`/persistent`** | emmc | defaults | `defaults` | **[V]** |
| 14 | `/dev/block/by-name/nvram` | `/nvram` | emmc | defaults | `defaults` | **[V]** |
| 15 | `/dev/block/by-name/proinfo` | `/proinfo` | emmc | defaults | `defaults` | **[V]** |
| 16 | `/dev/block/by-name/lk` | `/bootloader` | emmc | defaults | `defaults` | **[V]** |
| 17 | `/dev/block/by-name/lk2` | `/bootloader2` | emmc | defaults | `defaults` | **[V]** |
| 18 | `/dev/block/by-name/para` | **`/misc`** | emmc | defaults | `defaults` | **[V]** |
| 19 | `/dev/block/by-name/boot` | `/boot` | emmc | defaults | `first_stage_mount,nofail,slotselect` | **[V]** |
| 20 | `/dev/block/by-name/vbmeta_vendor` | `/vbmeta_vendor` | emmc | defaults | `first_stage_mount,nofail,slotselect` | **[V]** |
| 21 | `/dev/block/by-name/vbmeta_system` | `/vbmeta_system` | emmc | defaults | `first_stage_mount,nofail,slotselect,avb=vbmeta` | **[V]** |
| 22-28 | `logo`,`expdb`,`seccfg`,`tee1`,`tee2`,`scp1`,`scp2`,`sspm_1`,`sspm_2`,`md1img`,`md1dsp`,`md1arm7`,`md3img`,`gz1`,`gz2`,`spmfw`,`boot_para` | `/logo` … | emmc | defaults | `defaults` | **[V]** |
| 29 | `/dev/block/by-name/odmdtbo` | `/odmdtbo` | emmc | defaults | `defaults` | **[V]** |
| 30 | `/dev/block/by-name/dtbo` | `/dtbo` | emmc | defaults | `defaults` | **[V]** |
| 31 | `/dev/block/by-name/vbmeta` | `/vbmeta` | emmc | defaults | `defaults` | **[V]** |

Dynamic partitions / encryption / A-B summary **[V]**: `system`, `system_ext`, `vendor`, `product` are
`logical` (super) **and** `first_stage_mount` **and** `slotselect`; `/metadata` lives on **`md_udc`** (not
`metadata`); `/data` is FBE v2 (`aes-256-xts:aes-256-cts:v2`) **plus** metadata encryption
(`keydirectory=/metadata/vold/metadata_encryption`) with `inlinecrypt`; `checkpoint=block` (Virtual A/B quota);
nothing in this fstab uses the bare partition name form, everything is `/dev/block/by-name/…` + `slotselect`
where applicable.

### What the repo's `recovery.fstab` gets wrong

| repo line | problem | stock truth | conf |
| --- | --- | --- | --- |
| `/dev/block/by-name/misc /misc` | **no `misc` partition exists** on this device; the entry resolves to nothing (bootloader-message installs then silently fail) | `para` → `/misc` | **[V]** |
| `/dev/block/by-name/frp /frp` | wrong mount point; MTK/AVB tooling expects `/persistent` (`ro.frp.pst=/dev/block/by-name/frp`) | `frp` → `/persistent` | **[V]** |
| `/dev/block/by-name/nvdata /mnt/vendor/nvdata …` **and** `/dev/block/by-name/nvdata /nvdata …` | same block device listed twice → duplicate `TWPartition`, ambiguous backup/wipe target | nvdata is mounted **once**, at `/mnt/vendor/nvdata` | **[V]** |
| — | `dtbo`, `odmdtbo`, `vbmeta`, `vbmeta_vendor`, `vbmeta_system` are **missing** entirely | all five present in stock fstab | **[V]** |
| `system`/`system_ext` rows | dropped `avb_keys=/avb/q-gsi.avbpubkey:/avb/r-gsi.avbpubkey:/avb/s-gsi.avbpubkey` | present in stock (GSI keys) | **[V]** |
| `/dev/block/by-name/boot /boot emmc defaults slotselect` | missing `first_stage_mount,nofail` | stock has them | **[V]** |
| `nvram`,`proinfo`,`seccfg`,`expdb`,`boot_para`,`logo` marked `ro` | stock leaves them read-write (`defaults`) — harmless for backup, but `ro` blocks wiping `expdb`/`boot_para` from the GUI | `defaults` | **[V]** |
| `/dev/block/by-name/super /super emmc ro defaults` | not in stock fstab (super is not mountable); harmless as a TWRP visibility entry, keep it out of the flashable list | absent | **[V]** |

Everything else in the repo fstab (`md_udc`→`/metadata`, `/data` FBE v2 string, `protect1/2`, `nvcfg`,
`userdata` option list including the doubled `,,`) matches stock **byte-for-byte semantically** **[V]**.

---

## 6. `init.recovery.*.rc`, ueventd, `prop.default`

### 6.1 The two hardware names — critical

`prop.default` contains **no `ro.hardware` line** **[V]**. `ro.hardware` therefore comes from the kernel
cmdline `androidboot.hardware=mt6765`, which is baked into the **DTB `/chosen bootargs`** (§2) — not into the
boot header cmdline. The stock ramdisk hedges by shipping **both** names, byte-identical:

```
init.recovery.mt6762.rc  sha256 ba1e0fdb3fa1d90a…  ==  init.recovery.mt6765.rc
fstab.mt6762             sha256 cf5bb9def46364f6…  ==  fstab.mt6765  ==  system/etc/recovery.fstab
```

Consequence for the repo **[V]**: `recovery/root/` ships only `init.recovery.mt6762.rc`. With
`androidboot.hardware=mt6765`, `init` imports `/init.recovery.mt6765.rc`, so the repo's file is **never
executed** — `sys.usb.controller`, `sys.usb.configfs`, the CDP `cmode` write and the `adbd` start all silently
vanish (no adb in recovery). The import mechanism is right there in the stock ramdisk:

```
$ head -1 /root/work/bf61/rd_stock/system/etc/init/hw/init.rc
import /init.recovery.${ro.hardware}.rc
```

Ship the same content under **both** names.

### 6.2 Stock `init.recovery.mt6762.rc` (881 B, verbatim behaviour)

```
on init
    setprop sys.usb.configfs 1
    setprop sys.usb.controller "musb-hdrc"
    setprop sys.usb.ffs.aio_compat 1

on fs && property:ro.debuggable=0
    write /sys/class/udc/musb-hdrc/device/cmode 2      # CDP vs SDP detection
    start adbd

on post-fs
    symlink /dev/block/sda /dev/block/mmcblk0boot0     # A/B preloader in eMMC boot region
    symlink /dev/block/sdb /dev/block/mmcblk0boot1
    symlink /dev/block/mmcblk0boot0 /dev/block/platform/bootdevice/by-name/preloader_a
    symlink /dev/block/mmcblk0boot1 /dev/block/platform/bootdevice/by-name/preloader_b
    symlink /dev/block/mmcblk0boot0 /dev/block/by-name/preloader_a
    symlink /dev/block/mmcblk0boot1 /dev/block/by-name/preloader_b
    exec u:r:update_engine:s0 root root -- /system/bin/mtk_plpath_utils
```

Facts to carry over **[V]**:

- **USB controller = `musb-hdrc`** (MTK MUSB, matches `/usb0@11200000` = `mediatek,mt6765-usb20`).
  `sys.usb.configfs=1` and `sys.usb.ffs.aio_compat=1` are required by MTK's gadget stack.
- `ro.debuggable=0` in stock ⇒ the `on fs` block runs (CDP cmode + `start adbd`).
- **by-name / bootdevice symlink paths exist**: the rc file pins
  `/dev/block/platform/bootdevice/by-name/{preloader_a,preloader_b}` **and**
  `/dev/block/by-name/{preloader_a,preloader_b}`. The generic trees are created at runtime:
  `system/bin/init` contains `/dev/block/bootdevice/by-name`, `/dev/block/by-name/`; `system/bin/ueventd`
  contains `/dev/block/by-name/`, `/by-name/`, `/devices/platform/` **[V]**.
- `ro.boot.bootdevice` is **not** set by anything in the boot image: the boot cmdline has no
  `androidboot.bootdevice=` and `prop.default` has none **[V]**. Do not add
  `TW_USE_...`/bootdevice-dependent flags; use `/dev/block/by-name/…` paths (as the stock fstab does).
- eMMC boot region is exposed as SCSI disks (`/dev/block/sd[a-c]`, see also `mtk-plpath-utils.rc`
  `vendor.mtk.boot0_linka/b/c`), which is why the `mmcblk0boot*` symlinks are needed.

### 6.3 Services present in the stock ramdisk

| file | service | class | notes | conf |
| --- | --- | --- | --- | --- |
| `system/etc/init/mtk-plpath-utils.rc` | `mtk.plpath.utils.link` → `/system/bin/mtk_plpath_utils` | `main`, `oneshot`, `disabled`, root:root system | started by `on boot`; creates `preloader_raw_a/b` → `/dev/block/mapper/pl_a\|pl_b` and `bootloader1/2` → `lk1/lk2` symlinks behind `persist.vendor.mtk.pl_lnk=1`; `vendor.mtk.boot0_linka/b/c` maps `sd[a-c]`→`mmcblk0boot0` | **[V]** |
| `system/etc/init/snapuserd.rc` | `snapuserd` → `/system/bin/snapuserd` | `oneshot`, `disabled`, socket `snapuserd`, `u:r:snapuserd:s0` | **Virtual A/B (COW) is real on this device** | **[V]** |
| `system/etc/ueventd.rc` | — | — | **no** block/by-name rules at all; device nodes come from `ueventd` defaults | **[V]** |
| `system/etc/init/hw/init.rc` | — | — | only generic symlinks (`/bin`, `/etc`, usb gadget ffs links); no `ro.boot.*` handling | **[V]** |

### 6.4 `prop.default` properties that matter for TWRP

| property | value | why it matters | conf |
| --- | --- | --- | --- |
| `ro.board.platform` | `mt6765` | `TARGET_BOARD_PLATFORM := mt6765` ✔ (repo correct) | **[V]** |
| `ro.board.first_api_level` | `30` | device launched on API 30 (Android 11) with an Android-12 vendor image | **[V]** |
| `ro.build.version.release` / `.sdk` | `12` / `31` | branch `twrp-12.1` is right | **[V]** |
| `ro.build.version.security_patch` | `2024-03-05` | header only needs `2024-03` (see §8) | **[V]** |
| `ro.vndk.version` | `31` | VNDK 31 vendor blobs | **[V]** |
| `ro.zygote` | `zygote64_32` | 64-bit primary + 32-bit secondary → keep both ABIs | **[V]** |
| `ro.sf.lcd_density` | `210` | theme/UI density (§2) | **[V]** |
| `ro.surface_flinger.primary_display_orientation` | `ORIENTATION_0` | no rotation needed | **[V]** |
| `ro.hardware.hwcomposer` | `mtk_common` | HWC is MTK common — do not ship a Qualcomm-style HWC config | **[V]** |
| `ro.boot.dynamic_partitions` | `true` | super/logical mounts work | **[V]** |
| `ro.frp.pst` | `/dev/block/by-name/frp` | FRP partition is `frp`, mounted `/persistent` (§5) | **[V]** |
| `ro.product.ab_ota_partitions` | `boot,system,vendor` | A/B OTA set (§7) | **[V]** |
| `ro.debuggable` | `0` | stock is a user build | **[V]** |
| `persist.sys.usb.config` | `none` | no gadget configured at boot — recovery must set it | **[V]** |
| `ro.treble.enabled` / `ro.vndk.version` | `true` / `31` | Treble device, vendor in its own partition | **[V]** |
| `ro.hardware` | **absent** | comes from `androidboot.hardware=mt6765` (§6.1) | **[V]** |
| `ro.boot.bootdevice` | **absent** | use `/dev/block/by-name/…` | **[V]** |

---

## 7. A/B evidence, dynamic partitions, AVB

Slot-aware partitions actually present in the dumps (**[V]**, from file names + partition sizes):

| partition | A dump | B dump | size | conf |
| --- | --- | --- | --- | --- |
| `boot_a`/`boot_b` | populated, AVB-signed | **all zero** | 33554432 | **[V]** |
| `dtbo_a`/`dtbo_b` | populated, AVB-signed | **all zero** | 8388608 | **[V]** |
| `vbmeta_a`/`vbmeta_b` | AVB0, flags `0x3` | **all zero** | 8388608 | **[V]** |
| `vbmeta_system_a`/`_b` | AVB0, flags `0x3` | **all zero** | 8388608 | **[V]** |
| `vbmeta_vendor_a`/`_b` | AVB0, flags `0x3` | **all zero** | 11534336 / 13320192 | **[V]** |

Independent A/B signals:

1. fstab `slotselect` on `system`, `system_ext`, `vendor`, `product`, `boot`, `vbmeta_vendor`, `vbmeta_system`
   **[V]**.
2. `ro.product.ab_ota_partitions=boot,system,vendor` **[V]**.
3. `init.recovery.*.rc` creates `preloader_a`/`preloader_b` symlinks into the eMMC boot region — an A/B-only
   concern **[V]**.
4. `snapuserd` service + `super` partition (`BOARD_SUPER_PARTITION_SIZE` 5112119296 in the repo) + `/data`
   `checkpoint=block` ⇒ **Virtual A/B** **[V]**.
5. `vbmeta_a` chains to `boot` (rollback loc 3), `vbmeta_system` (2), `vbmeta_vendor` (4) **[V]**.

⇒ `AB_OTA_UPDATER := true` is correct and **currently missing from `BoardConfig.mk`** **[V]**.
Slot B being all-zero means the device runs slot A only (B not provisioned), which is normal for a
shipped-single-slot A/B product; TWRP must therefore not assume `_b` content exists.

AVB state **[V]**: every signed vbmeta has `flags = 0x3` = `AVB_VBMETA_IMAGE_FLAGS_HASHTREE_DISABLED (1) |
AVB_VBMETA_IMAGE_FLAGS_VERIFICATION_DISABLED (2)`, release string `avbtool 1.2.0`. So on this device
**dm-verity and AVB verification are both off** — flashing an unsigned `boot.img` needs no
`fastboot --disable-verification flash vbmeta` and no `--disable-verity`. Descriptor contents:

```
vbmeta_a        : CHAIN boot / vbmeta_system / vbmeta_vendor ; HASH dtbo image_size=37792 ;
                  PROPERTY com.android.build.{product,system_ext}.{fingerprint,os_version,security_patch},
                  com.android.build.dtbo.fingerprint
vbmeta_system_a : PROPERTY com.android.build.system.*  ; (hashtree descriptors for system/system_ext)
vbmeta_vendor_a : PROPERTY com.android.build.vendor.*  ; (hashtree for vendor/odm)
```

Fingerprints inside vbmeta pin the vendor BSP exactly **[V]**:

```
com.android.build.vendor.fingerprint   = alps/vnd_k62v1_64_bsp/k62v1_64_bsp:12/SP1A.210812.016/mp1V1…
com.android.build.dtbo.fingerprint     = alps/vnd_k62v1_64_bsp/k62v1_64_bsp:12/SP1A.210812.016/mp1V1…
com.android.build.system.fingerprint   = alps/sys_mssi_64_cn/mssi_64_cn:14/UP1A.231005.007/mp1V546:u…
```

i.e. vendor/dtbo build tree = **k62v1_64_bsp, Android 12 (SP1A.210812.016)**; the system side was built from
an `mssi_64_cn` header stamped `14/UP1A.231005.007` (an MTK quirk — the installed system image is 12-era, the
stamp is not). `vendor/build.prop` inside the ramdisk confirms the boot image itself
(`/root/work/bf61/rd_stock/system/etc/ramdisk/build.prop`) **[V]**:

```
ro.product.bootimage.device=k62v1_64_bsp
ro.bootimage.build.fingerprint=alps/vnd_k62v1_64_bsp/k62v1_64_bsp:12/SP1A.210812.016/mp1V15240:user/release-keys
ro.bootimage.build.date=Tue May 20 20:47:04 CST 2025
ro.bootimage.build.version.sdk=31
```

---

## 8. Exact `mkbootimg` arguments, and the real BoardConfig variable name

### 8.1 The variable name (asked explicitly)

In **AOSP 12.1.0_r4** `build/make` the name is **`BOARD_BOOT_HEADER_VERSION`**; `BOARD_BOOTIMG_HEADER_VERSION`
does not exist anywhere.

```
$ grep -c BOARD_BOOTIMG_HEADER_VERSION /tmp/Makefile.android-12.1.0_r4          # core/Makefile, AOSP 12.1.0_r4
0
$ grep -n  BOARD_BOOT_HEADER_VERSION  /tmp/Makefile.android-12.1.0_r4
(no hits in core/Makefile — it is consumed by core/board_config.mk and bootable/recovery)
$ grep -n BOARD_BOOT_HEADER_VERSION /tmp/android_build/core/board_config.mk      # TeamWin build/make, 12.1
28:_board_strip_readonly_list += BOARD_BOOT_HEADER_VERSION
420:ifdef BOARD_BOOT_HEADER_VERSION
421:  ifneq ($(call math_gt_or_eq,$(BOARD_BOOT_HEADER_VERSION),3),)
908:  ifneq (,$(call math_lt,$(BOARD_BOOT_HEADER_VERSION),4))
911:        BOARD_BOOT_HEADER_VERSION is less than 4)
```

Also **[V]** from `/tmp/android_build/target/board/BoardConfigEmuCommon.mk:77-78` — the canonical two-line idiom,
where the header version is *only* ever passed to `mkbootimg` through `BOARD_MKBOOTIMG_ARGS`:

```make
BOARD_BOOT_HEADER_VERSION := 4
BOARD_MKBOOTIMG_ARGS += --header_version $(BOARD_BOOT_HEADER_VERSION)
```

And `core/Makefile` itself never emits `--header_version` (grep for `header_version` in AOSP 12.1.0_r4
`core/Makefile`: **0 hits**); it only emits the version/patch args
(`/tmp/twbuild/core/Makefile:933-935`, identical text in AOSP):

```make
INTERNAL_MKBOOTIMG_VERSION_ARGS := \
    --os_version $(PLATFORM_VERSION_LAST_STABLE) \
    --os_patch_level $(PLATFORM_SECURITY_PATCH)
```

Therefore, in the repo's `BoardConfig.mk`, `BOARD_BOOTIMG_HEADER_VERSION` is a **dead variable that happens to
work** only because it is expanded inside `BOARD_MKBOOTIMG_ARGS += --header_version $(BOARD_BOOTIMG_HEADER_VERSION)`.
The consequences of the wrong name are real **[V]**: `core/board_config.mk` never sees a header version (so
`BUILDING_VENDOR_BOOT_IMAGE` and the `<4` sanity checks are skipped) and the TWRP tree never gets
`-DBOARD_BOOT_HEADER_VERSION`, which is what seeds `tw_boot_header_version` used when repacking. Verified in
the local 12.1 recovery tree:

```
bootable/recovery/Android.mk:174-175
    ifneq ($(BOARD_BOOT_HEADER_VERSION),)
        LOCAL_CFLAGS += -DBOARD_BOOT_HEADER_VERSION=$(BOARD_BOOT_HEADER_VERSION)
bootable/recovery/data.cpp:825-826
    #ifdef BOARD_BOOT_HEADER_VERSION
        mConst.SetValue("tw_boot_header_version", BOARD_BOOT_HEADER_VERSION);
bootable/recovery/twrpRepacker.cpp:140
        if (DataManager::GetIntValue("tw_boot_header_version") == 4) { ... }
```

Rename it to `BOARD_BOOT_HEADER_VERSION := 2` and keep the `BOARD_MKBOOTIMG_ARGS` line.

### 8.2 The exact argument set that reproduces the stock header

Verified field-by-field against `boot_a.img` **[V]**:

```bash
mkbootimg \
  --kernel    prebuilt/kernel \
  --ramdisk   <ramdisk.gz> \
  --dtb       prebuilt/dtb.img \
  --cmdline   "bootopt=64S3,32N2,64N2 buildvariant=user androidboot.selinux=permissive" \
  --base      0x40078000 \
  --kernel_offset  0x00008000 \
  --ramdisk_offset 0x11a88000 \
  --tags_offset    0x07808000 \
  --dtb_offset     0x07808000 \
  --pagesize       2048 \
  --header_version 2 \
  --os_version     12.0.0 \
  --os_patch_level 2024-03 \
  --board          "" \
  --output    boot.img
```

Why each value is forced:

| arg | must be | evidence |
| --- | --- | --- |
| `--header_version 2` | 2 | `@0x28 = 2`; also keeps `dtb` inside `boot.img` (v3 would move it to vendor_boot, §4) **[V]** |
| `--pagesize 2048` | 2048 | `@0x24 = 0x800`; segments align to 2048 **[V]** |
| `--base` | `0x40078000` | `kernel_addr 0x40080000 − 0x8000` **[V]** |
| `--kernel_offset` | `0x00008000` | **[V]** |
| `--ramdisk_offset` | `0x11a88000` | `0x51b00000 − base` **[V]** |
| `--tags_offset` | `0x07808000` | `0x47880000 − base` **[V]** |
| `--dtb_offset` | `0x07808000` | `dtb_addr 0x47880000 − base` **[V]** |
| `--os_version`/`--os_patch_level` | `12.0.0` / `2024-03` | `mkbootimg.py` computes `(parse_os_version('12.0.0') << 11) \| parse_os_patch_level('2024-03-01')` = `(0x30000<<11)\|0x183 = 0x18000183` = header **[V]** |
| `--board ""` | empty | `name[16]` is 16 zero bytes **[V]** |
| **no `--second`** | absent | `second_size = 0`; AOSP `mkbootimg.py` writes `second_addr = base+offset if filesize(second)>0 else 0`, which is why the stock `second_addr` is **0** despite MTK's customary `0x00e88000` **[V]** *(source: `system/tools/mkbootimg/mkbootimg.py` @ android-12.1.0_r4, `second_load_address = ((args.base + args.second_offset) if filesize(args.second) > 0 else 0)`)* |
| **no `--recovery_dtbo`** | absent | `recovery_dtbo_size = 0` at `0x660` **[V]** |
| `--dtb` = the dt_table container | verbatim 101729 B | `dtb_size = 0x18d61`; the file starts with `d7b7ab1e`, so `--dtb` must receive the container, **not** a bare FDT **[V]** |

Byte-for-byte reality check:

- Header bytes `0x0000–0x067B` reproduce **exactly**; `0x067C–0x07FF` are zero padding **[V]**.
- Bytes that necessarily change in a TWRP build: `id` at `0x240` (sha1 over kernel+ramdisk+dtb — the
  ramdisk is ours), `ramdisk_size` at `0x10`, and everything from `0x000800` onward except the kernel/dt
  payload. The pay-off is that AVB verification is disabled (§7), so a differing `id` is harmless.
- `BOARD_SECOND_OFFSET := 0x00e88000` in the repo is inert/harmless but misleading: with
  `second_size == 0` the header always carries `0`. Leave it out; do not "fix" `second_addr`.
- `BOARD_KERNEL_CMDLINE` in the repo already appends `buildvariant=user`, and `core/Makefile:909` appends
  `buildvariant=$(TARGET_BUILD_VARIANT)` again → an `eng`/`userdebug` build produces
  `… buildvariant=user buildvariant=userdebug …` **[V]**. Drop `buildvariant` from `BOARD_KERNEL_CMDLINE`
  (keep `bootopt=64S3,32N2,64N2 androidboot.selinux=permissive`) if a stock-identical cmdline matters; the
  kernel takes the last occurrence, so this is cosmetic, not fatal.
- `TARGET_PREBUILT_DTB := …` is not consumed by AOSP 12.1 for `--dtb` (only `BOARD_INCLUDE_DTB_IN_BOOTIMG` +
  `BOARD_PREBUILT_DTBIMAGE_DIR` are, and that path `cat`s `*.dtb` files — wrong for a dt_table container).
  Passing `--dtb` through `BOARD_MKBOOTIMG_ARGS`, as the repo does, is the correct approach **[V]**.

---

## Appendix A — copy/paste verified values

```make
# boot image / header  (all [V], see §1, §8)
BOARD_BOOT_HEADER_VERSION := 2                 # was BOARD_BOOTIMG_HEADER_VERSION (dead name)
BOARD_KERNEL_BASE         := 0x40078000
BOARD_KERNEL_PAGESIZE     := 2048
BOARD_KERNEL_OFFSET       := 0x00008000        # informational only
BOARD_RAMDISK_OFFSET      := 0x11a88000        # informational only
BOARD_KERNEL_TAGS_OFFSET  := 0x07808000        # informational only
BOARD_DTB_OFFSET          := 0x07808000        # informational only
BOARD_KERNEL_CMDLINE      := bootopt=64S3,32N2,64N2 androidboot.selinux=permissive
BOARD_MKBOOTIMG_ARGS += --header_version 2 --base 0x40078000 --pagesize 2048 \
    --kernel_offset 0x00008000 --ramdisk_offset 0x11a88000 \
    --tags_offset 0x07808000 --dtb_offset 0x07808000 \
    --dtb $(DEVICE_PATH)/prebuilt/dtb.img
BOARD_KERNEL_IMAGE_NAME := Image.gz            # gzip, verified
# BOARD_RAMDISK_USE_LZ4 must stay unset (stock ramdisk is gzip)  [V]

# partitions  [V]
BOARD_BOOTIMAGE_PARTITION_SIZE   := 33554432
BOARD_DTBOIMG_PARTITION_SIZE     := 8388608
BOARD_SUPER_PARTITION_SIZE       := 5112119296

# A/B + recovery-in-boot  [V]
AB_OTA_UPDATER            := true              # missing in repo
BOARD_USES_RECOVERY_AS_BOOT := true
TW_HAS_NO_RECOVERY_PARTITION := true
# no vendor_boot: never set BOARD_BOOT_HEADER_VERSION >= 3   [V]

# platform / display  [V]/[I]
TARGET_BOARD_PLATFORM := mt6765
TW_THEME              := portrait_hdpi          # 720x1280 panel, 16:9 → uniform 0.667 scale  [I, high]
TW_BRIGHTNESS_PATH    := "/sys/class/leds/lcd-backlight/brightness"   # ledger led@6 in dtbo  [V]
```

Ramdisk files that must exist (both hardware names, identical content) **[V]**:

```
recovery/root/init.recovery.mt6765.rc     # ro.hardware = androidboot.hardware = mt6765  ← currently missing
recovery/root/init.recovery.mt6762.rc     # harmless duplicate, stock ships both
```

---

## Appendix B — deltas against the current repo (all **[V]** unless tagged)

| repo location | current | fact | action |
| --- | --- | --- | --- |
| `BoardConfig.mk` | `BOARD_BOOTIMG_HEADER_VERSION := 2` | real variable is `BOARD_BOOT_HEADER_VERSION` (§8) | rename; keep `--header_version` in `BOARD_MKBOOTIMG_ARGS` |
| `BoardConfig.mk` | no `AB_OTA_UPDATER` | device is A/B, Virtual A/B, recovery-in-boot (§7) | `AB_OTA_UPDATER := true` |
| `BoardConfig.mk` | `BOARD_SECOND_OFFSET := 0x00e88000` | `second_size = 0` ⇒ header `second_addr = 0` always (§1, §8) | drop it (inert, misleading) |
| `BoardConfig.mk` | `BOARD_KERNEL_CMDLINE := … buildvariant=user …` | build appends `buildvariant=$(TARGET_BUILD_VARIANT)` again (§8) | remove `buildvariant` from the cmdline |
| `BoardConfig.mk` | `TARGET_PREBUILT_DTB := …/prebuilt/dtb.img` | not consumed by AOSP 12.1 for `--dtb`; `dtb.img` is a **dt_table container**, not a bare FDT (§2) | harmless, but `--dtb` via `BOARD_MKBOOTIMG_ARGS` is the thing that works (already present) |
| `BoardConfig.mk` | `TW_THEME := portrait_mdpi` | LCM identity says 720×1280 → 16:9 theme (§2) | `portrait_hdpi`, verify with `fb0/virtual_size` |
| `BoardConfig.mk` | base/offsets/pagesize/cmdline `bootopt=`/`bootimage header 2` | all reproduce the stock header exactly (§8) | keep — verified correct |
| `BoardConfig.mk` | `TW_BRIGHTNESS_PATH := /sys/class/leds/lcd-backlight/brightness` | dtbo `led@6` = `mediatek,lcd-backlight` (§3) | keep — verified correct |
| `BoardConfig.mk` | platform `mt6765`, boot/dtbo partition sizes | match dumps and `ro.board.platform` (§6.4) | keep — verified correct |
| `recovery.fstab` | `misc`, `/frp`, duplicate `nvdata`, no `dtbo/odmdtbo/vbmeta*` | stock: `para`→`/misc`, `frp`→`/persistent`, single nvdata, five extra entries (§5) | fix per §5 |
| `recovery/root/` | only `init.recovery.mt6762.rc` | `ro.hardware = mt6765` ⇒ the mt6765 file is the one imported (§6.1) | add `init.recovery.mt6765.rc` (identical) |
| `README.md` | "Display 480×800, portrait" | unverified; primary evidence says 720×1280 (§2) | correct after on-device `fb0` check |
| `prebuilt/kernel`, `prebuilt/dtb.img` | — | byte-identical to stock (§1) | keep — verified correct |
| `prebuilt/dtbo.img` | full 8 MiB partition dump | byte-identical to `dtbo_a.img`, includes MTK `cert1` + AVB footer (§3) | keep for flashing; `research/artifacts/dtbo.img` (34051 B) is the canonical-format copy |
