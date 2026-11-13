# TWRP for Famue BF61（MT6762 / mt6765 BSP）

TeamWin Recovery Project **twrp-12.1** 设备树。本机是 A/B + recovery-as-boot：
**没有 recovery 分区**，TWRP 的 ramdisk 直接打进 `boot.img`，刷 `boot` 分区。

- 构建目标：`mka bootimage` → `out/target/product/bf61/boot.img`
- lunch：`twrp_bf61-eng`
- boot 分区只有 **32 MiB**，内核已占 10.9 MiB，ramdisk 必须瘦身（见 §3.7）
- 自检：`python3 tools/check-tree.py` / `bash tools/check-tree.sh`（CI 构建前必跑）

---

## 1. 设备事实表（都从 stock 镜像里量出来，非猜测）

| 项 | 值 | 证据 |
|---|---|---|
| SoC / BSP | MT6762，DT model `MT6765`，平台树 `mt6765` | `boot_a.img` 的 dtb `/model` |
| `ro.hardware` | **mt6765**（不是 mt6762） | dtb `/chosen` 的 `androidboot.hardware=mt6765` |
| 内核 | 4.19.191，`Image.gz`，11,465,967 B | boot header + gzip 解压 |
| boot 镜像 | header **v2**、page size **2048**、header_size 1660 | boot header |
| 地址 | base `0x40078000`，kernel `0x40080000`，ramdisk `0x51b00000`，tags/dtb `0x47880000` | boot header 反推，全部对齐 |
| cmdline | `bootopt=64S3,32N2,64N2 buildvariant=user androidboot.selinux=permissive` | boot header（build 会改写 buildvariant） |
| dtb 段 | 101,729 B，MTK 单条 **dt_table 容器**（magic `0xd7b7ab1e`，表内 1 条 FDT） | boot 尾部 + `prebuilt/dtb/mt6765.dtb` |
| dtbo 分区 | `dt_table`，真实长度 **34,051 B**（不是 8 MiB） | `dtbo_a.img` |
| vendor_boot | 64 MiB **全零**，无 `VNDRBOOT` 头 | `vendor_boot_a/b.img` |
| 分区 | A/B；`boot` 32 MiB、`dtbo` 8 MiB、`super` 5,112,119,296 B | 分区转储 + stock fstab |
| Virtual A/B | 真 VAB：`ro.virtual_ab.enabled/compression/userspace.snapshots` 全 true；OTA 快照在 super 空闲空间（COW/dm-user），状态在 `/metadata/ota`；stock recovery 自带 `snapuserd` | stock `prop.default:133,134,287` |
| 动态分区 | `system system_ext vendor product` 在 super 里（`logical`） | stock `fstab.mt6762` |
| 加密 | FBE v2 `aes-256-xts:aes-256-cts:v2`；`/metadata`(`md_udc`) + `keydirectory=/metadata/vold/metadata_encryption` | stock fstab |
| keymaster / gatekeeper | HIDL keymaster 4.1、gatekeeper 1.0（TWRP 12.1 只连这两条 HIDL 链） | vendor manifest（需上机复核，见 §7） |
| 显示 | 面板 LCM 串为 `r63306_hd720_dsi_vdo_xiapu_4p3`，倾向 720×1280；反证：density 210、stock recovery 资源是 mdpi 桶、机器标称 4 寸 | kernel / stock ramdisk，**未定论** |
| USB | `musb-hdrc` + configfs（MTK） | stock `init.recovery.mt6762.rc`、dtb `usb0@11200000` |
| AVB | 全部 vbmeta `flags=0x3`（hashtree/verification 都关） | `vbmeta*.img` |

---

## 2. 仓库结构

```
.
├── AndroidProducts.mk              # lunch 菜单：twrp_bf61-eng
├── twrp_bf61.mk                    # 产品定义：aosp_base → vendor/twrp → device.mk
├── device.mk                       # 内核落盘、TW_* 开关、system.prop、动态分区
├── BoardConfig.mk                  # 内核/DTB/分区/AB_OTA_UPDATER/加密
├── vendorsetup.sh                  # ALLOW_MISSING_DEPENDENCIES
├── system.prop                     # 追加进 ramdisk prop.default
├── prebuilt/
│   ├── kernel                      # stock boot_a 原样提取（Image.gz）
│   ├── dtb/mt6765.dtb              # MTK dt_table 容器（不是裸 FDT）
│   └── dtbo.img                    # 裁到 34,051 B
├── recovery/root/
│   ├── init.recovery.mt6765.rc     # 主 rc（ro.hardware=mt6765）
│   ├── init.recovery.mt6762.rc     # 一行 import 兜底
│   ├── ueventd.mt6765.rc           # TEE/RPMB 节点权限
│   └── system/etc/
│       ├── recovery.fstab          # AOSP v2 主表（fs_mgr/vold 也会读）
│       └── twrp.flags              # TWRP 私有 flag（v1，分号）
├── tools/check-tree.py             # 静态自检（CI 门禁）
├── ci/{build.sh,bf61.env}          # 本地/CI 共用构建脚本
└── .github/workflows/build.yml     # GitHub Actions
```

`recovery/root/` 会整目录进 ramdisk；**不要**在它下面创建真实 `etc/` 目录，
否则会覆盖 ramdisk 里 `/etc -> /system/etc` 的软链（TWRP 找不到 `/etc/twrp.flags`）。

---

## 3. 设计说明（为什么这么写）

### 3.1 形态与构建目标
`BOARD_USES_RECOVERY_AS_BOOT := true` + header v2 → `mka bootimage`。
`vendor_boot` 是全零分区，不参与；不要开 `BOARD_MOVE_RECOVERY_RESOURCES_TO_VENDOR_BOOT`，
也不要 `mka vendorbootimage`。

### 3.2 内核 / DTB / DTBO
- `TARGET_PREBUILT_KERNEL` 只告诉 build 内核路径；TeamWin build fork 不消费它，
  所以 `device.mk` 必须再 `PRODUCT_COPY_FILES += ...:kernel`。
- 12.1 不会自动把 `BOARD_*_OFFSET` 变成 mkbootimg 参数，全部显式写进 `BOARD_MKBOOTIMG_ARGS`，
  并额外传 `--header_version 2`。
- dtb 用官方双件套：`BOARD_INCLUDE_DTB_IN_BOOTIMG` + `BOARD_PREBUILT_DTBIMAGE_DIR`。
  build 只会把目录里的 `*.dtb` 按字典序 `cat` 起来，mtk 的 dt_table 容器原样透传。
- `prebuilt/dtbo.img` 已裁到 `total_size`，但 `BOARD_DTBOIMG_PARTITION_SIZE` 仍是 8 MiB 整分区。

### 3.3 两份 fstab 的分工
`recovery.fstab` 用 **AOSP v2 顺序**（`<src> <mnt> <type> <mount opts> <flags>`）：
它不只给 TWRP 用，vold 的 `ReadDefaultFstab()` 在 recovery 下也会直接读
`/etc/recovery.fstab`（`system/core/fs_mgr`），所以第 5 列只能写 AOSP 认识的 flag。

TWRP 私有语义（`display=`、`backup=`、`flashimg=`、`storage`、`mounttodecrypt`…）放在
`twrp.flags`，**v1 格式、只能用 `;` 分隔**（源码对 `/etc/twrp.flags` 强制 v1 解析）。
写在主表第 4 列（mount options）里的 TWRP flag 不会生效。

`TW_SKIP_ADDITIONAL_FSTAB := true`：否则 `/vendor` 挂上后 TWRP 会再解析
`/vendor/etc/fstab.<hw>`，把 `/data`、`/metadata` 替换掉，且第二趟不带 twrp.flags。
本树已完整镜像 stock 的分区与加密 flag，不需要二次导入。

### 3.4 A/B、动态分区与 Virtual A/B
`AB_OTA_UPDATER := true` 是硬要求：TWRP 靠它给 super 里的 dm 分区名补 `_a/_b`；
不写会让 `Prepare_Super_Volume()` 拿裸名找 dm 设备并死等。
`/super` 不要手写：TWRP 的 `Setup_Super_Partition()` 会自己加，且不去重。

本机是**真 Virtual A/B**（stock prop.default：`ro.virtual_ab.enabled=true` +
`ro.virtual_ab.compression.enabled=true` + `ro.virtual_ab.userspace.snapshots.enabled=true`，
OTA 用 super 空闲空间做 COW 快照，合并状态记录在 `/metadata/ota`）。
这组属性必须出现在 recovery ramdisk 的 prop.default 里，否则 TWRP 会把本机当非 VAB：

- `Format Data` 不会先跑 `Check_Pending_Merges()`（`partitionmanager.cpp:1770`）——
  OTA 半途（pending merge）时清 data 有数据损坏风险；
- OTA zip 安装完成后不会重映射 super（`twinstall.cpp:344`）；
- 重启询问与 `tw_virtual_ab` UI 状态判定（`recovery.cpp:322`、`data.cpp:840`）走错分支。

写法：device.mk 继承 `$(SRC_TARGET_DIR)/product/virtual_ab_ota.mk`（AOSP 标准件，
带 `ro.virtual_ab.enabled=true` + e2fsck_ramdisk；twrp_coral / los_gs201 同款），
compression / userspace-snapshots 两个开关放 system.prop，与 stock 逐字一致。

### 3.5 `ro.hardware = mt6765`
dtb `/chosen` 里是 `androidboot.hardware=mt6765`，所以主 init rc 必须叫
`init.recovery.mt6765.rc`（叫 mt6762 会静默不加载 → 无 adb / 无 USB）。
`init.recovery.mt6762.rc` 只保留一行 `import` 兜底（stock ramdisk 两个名字都带）。

### 3.6 解密与 vendor HAL 的启动时机
TWRP 12.1 的 FBE 解密链是 `vold/fscrypt + keystore2 + keymaster(4.x) + gatekeeper(1.0)`，
它只负责**连接** HAL，不负责拉起。HAL 二进制在 `/vendor/bin/hw`，而 `/vendor` 是 super
逻辑分区，只有 TWRP 自己挂载后才可见。

因此本树：
1. `/vendor`、`/metadata` 在 twrp.flags 里带 `mounttodecrypt`；
2. `init.recovery.mt6765.rc` 用 `on property:twrp.mount_to_decrypt=1` 触发
   `start vendor.keymaster-4-1` / `start vendor.gatekeeper-1-0`
   （该属性由 `PartitionManager::Decrypt_Data()` 在挂完这些分区后设置）。

若首启解密失败，先看 `recovery.log` 里是 `failed to get gatekeeper service`（HAL 没起/路径不对）
还是 `Unknown password type` / `read_key failed`（key 目录或 metadata 参数不对）。

### 3.7 体积
boot 32 MiB − 内核 10.9 MiB − dtb 0.1 MiB ≈ **20.8 MiB 给 ramdisk.gz**。
当前取舍：排除 nano/bash（`TW_EXCLUDE_NANO/BASH`）、不装额外语言包、排除 APEX 加载；
**TTF 不能砍**（recovery 硬链接 libft2，砍掉会开机崩），所以 `TW_DISABLE_TTF` 整行不写。
`TW_INCLUDE_NTFS_3G` 保留（USB OTG 放 NTFS 盘）；如果超限，优先关它。

---

## 4. 构建

### 本地
```bash
repo init --depth=1 -u https://github.com/minimal-manifest-twrp/platform_manifest_twrp_aosp.git -b twrp-12.1
repo sync -c -j8 --force-sync --no-clone-bundle --no-tags

git clone <this-repo> device/famue/bf61
cd device/famue/bf61 && bash tools/check-tree.sh . && cd -

set +u
. build/envsetup.sh
lunch twrp_bf61-eng
set -u
mka bootimage -j$(nproc)
```
产物 `out/target/product/bf61/boot.img`；`assert-max-image-size` 会在超过 32 MiB 时直接报错。

### CI
`.github/workflows/build.yml` 调 `ci/build.sh ci/bf61.env`：
- 清盘后自建 8 GB swap（不用 `free-disk-space` 的 `swap-storage=true`，那是删 swap）
- `JOBS=4`、`NINJA_HIGHMEM_NUM_JOBS=2`（4 vCPU / 16 GB + 8 GB swap）
- 用 `${{ github.workspace }}` 复制设备树进源码树，**构建的就是被推送的 commit**
- 构建前 `tools/check-tree.sh` 门禁；构建后解析 boot header 校验 v2 / 2048 / dtb / cmdline
- 产物：`boot.img`、`boot.img.sha256`、`build.log`、`out-ci/*.log|txt`

### 验证 header（不用上机）
```bash
python3 - <<'PY'
import struct
d=open('out/target/product/bf61/boot.img','rb').read()
print(d[:8], struct.unpack_from('<10I', d, 8))
print('cmdline:', d[0x40:0x240].split(b'\0')[0].decode())
hdr = struct.unpack_from('<10I', d, 8)          # kernel/ramdisk/second/tags/page/hv/osv
dtb_size, dtb_addr = struct.unpack_from('<QQ', d, 0x670)
print('dtb_size', dtb_size, 'dtb_addr', hex(dtb_addr))
PY
```
或者用 AOSP 自带工具：`unpack_bootimg --boot_img boot.img --out /tmp/unp && cat /tmp/unp/bootimg_info`。

---

## 5. 刷入、备份、回滚

> 先 `fastboot boot` 验证，再 `fastboot flash`。刷 boot 前务必把 stock `boot_a.img` 留好。

```bash
adb reboot bootloader
fastboot getvar current-slot          # 记下 _a/_b
fastboot boot out/target/product/bf61/boot.img     # 只启动，不写盘
# 确认能进 TWRP、触摸/显示/adb 正常后：
fastboot flash boot out/target/product/bf61/boot.img
fastboot reboot recovery
```

- 本机所有 `vbmeta` 的 AVB flags 都是 `0x3`（hashtree/verification 关闭），
  刷未签名 boot **不需要** `--disable-verification`。
- A/B：只刷当前 slot 的 boot；slot B 是空分区，不要 `--set-active=b` 启动。
- 回滚：`fastboot flash boot bf61_backup/boot_a.img`（本仓库 `.gitignore` 已忽略该目录）。
- 想要 pc 端救砖：`fastboot flash boot` 失败时仍可用 `fastboot boot stock_boot.img`
  或 MTK SP Flash Tool（preloader 模式）恢复。

---

## 6. 首启验收与排障

```bash
adb devices
adb shell getprop ro.hardware                 # 期望 mt6765
adb shell getprop ro.boot.slot_suffix         # _a / _b
adb shell cat /sys/class/graphics/fb0/virtual_size   # 定论面板分辨率
adb shell ls /sys/class/leds/                 # 确认 lcd-backlight
adb shell ls /vendor/bin/hw | grep -E 'keymaster|gatekeeper'
adb shell ps -A | grep -E 'keymaster|gatekeeper|keystore'
adb pull /tmp/recovery.log
grep -E "Unhandled flag|Failed to mount|keymaster|gatekeeper|metadata|fscrypt|Decrypt" /tmp/recovery.log
```

| 症状 | 先查 |
|---|---|
| 开机黑屏/花屏 | `TW_THEME` 与真实分辨率（见 §7）；dtb 是否被换成裸 FDT |
| 触摸无反应 | `getevent -lp`；MTK tpd 驱动是否内置 |
| 无 adb | init rc 文件名是否 `mt6765`；`sys.usb.controller=musb-hdrc`；configfs |
| 内部存储 0MB | `/data` 是否解开；`keydirectory`/`metadata_encryption` 是否与 vendor fstab 一致 |
| 解密失败提示 gatekeeper | vendor HAL 没起：`ps`、`/vendor/bin/hw` 路径、`dmesg | grep avc` |
| 逻辑分区 0 字节 | `AB_OTA_UPDATER` 是否生效；`/dev/block/by-name/super` 是否存在 |
| 备份列表没有某分区 | `twrp.flags` 是否给了 `backup=1` |

---

## 7. 尚未上机验证的点（诚实清单）

1. **面板分辨率**：LCM 串倾向 720×1280，但 density 210 / stock mdpi 资源 / 4 寸标称倾向 480×800。
   当前 `TW_THEME := portrait_mdpi` 对两种面板都能用（720p 下仅约 6% 纵向拉伸）；
   上机 `cat /sys/class/graphics/fb0/virtual_size` 后按结论改 `TW_THEME` 与 `TARGET_SCREEN_*`。
2. **metadata 加密参数**：`metadata_encryption=aes-256-xts:wrappedkey_v0` 是按 AOSP 12 约定补的，
   stock 的 first_stage fstab 里没有这一项。解密失败时先与 `/vendor/etc/fstab.mt6765`
   里的同名 flag 对齐。
3. **vendor HAL 路径/接口**：`/vendor/bin/hw/android.hardware.keymaster@4.1-service`、
   `...gatekeeper@1.0-service` 是按 HIDL 4.1/1.0 的常见形态写的，需用 `ls /vendor/bin/hw` 复核。
   如果该机是 AIDL keymint，TWRP 12.1 的 HIDL 链连不上，需要换 14.1 分支或补 shim。
4. **触摸/亮度节点**：`TW_BRIGHTNESS_PATH` 取自 MTK 通用路径，未实机确认。
5. 本次重写只做了静态校验（自检脚本 + 指南 linter + boot header 复算），**没有实际编译/上机**。

---

## 8. 相对旧树改了什么

| # | 旧树 | 新树 | 原因 |
|---|---|---|---|
| 1 | 无 `AB_OTA_UPDATER` | 补 `AB_OTA_UPDATER := true` + `AB_OTA_PARTITIONS` | super 逻辑分区 dm 名要带 `_a/_b`，否则死等 |
| 2 | `BOARD_BOOTIMG_HEADER_VERSION`（死变量） | `BOARD_BOOT_HEADER_VERSION := 2` | 12.1 只消费后者（`-D` 进 TWRP） |
| 3 | fstab 两份（根 + `recovery/root/etc`） | 只留 `recovery/root/system/etc/recovery.fstab` | 真实 `/etc` 目录会破掉软链 |
| 4 | 无 `twrp.flags` | 新增（v1 + 分号） | TWRP 私有 flag 的正确落点 |
| 5 | `/data` 缺 `metadata_encryption=` | 三件套齐（file/metadata/keydirectory） | FBEv2 metadata 解密必需 |
| 6 | 缺 `vendorsetup.sh`/`system.prop` | 补齐 | minimal manifest lunch、recovery 属性 |
| 7 | 内核没拷进 PRODUCT_OUT | `LOCAL_KERNEL` + `PRODUCT_COPY_FILES:kernel` | TeamWin build fork 不消费 `TARGET_PREBUILT_KERNEL` |
| 8 | dtb 用 `--dtb` 单变量透传 | 官方 `BOARD_INCLUDE_DTB_IN_BOOTIMG` + `BOARD_PREBUILT_DTBIMAGE_DIR` | 与 build 系统一致，改 dtb 有依赖跟踪 |
| 9 | dtbo.img 是 8 MiB 整分区转储 | 裁到 34,051 B | 体积/正确性 |
| 10 | `/super` 手写、nvdata 挂两次 | 删 `/super`、每块设备只挂一次 | TWRP 自己生成 super；重复会误格式化 |
| 11 | `/frp`、`/misc` 名字与 stock 不一致 | `/persistent`(frp)、`/misc`(para) | 与 stock fstab 对齐 |
| 12 | 缺 dtbo/vbmeta* 条目 | twrp.flags 补全 | A/B 备份/刷 img |
| 13 | `TW_HAS_NO_RECOVERY_PARTITION` 等死开关 | 删除 | 12.1 无消费者 |
| 14 | `TW_DISABLE_TTF := false` 注释自相矛盾 | 整行删除（默认保留 TTF） | 砍 TTF 会开机崩 |
| 15 | init rc 叫 `mt6762` | `mt6765` + mt6762 import 兜底 | 实际 ro.hardware=mt6765 |
| 16 | HAL service 无 disabled/无启动触发 | `on property:twrp.mount_to_decrypt=1` 启动 | 等 /vendor 挂载后再 exec |
| 17 | `ENABLE_VIRTUAL_AB := true` + 继承 `virtual_ab_ota.mk`（属性层面） | 改为标准继承 `virtual_ab_ota.mk` + system.prop 补 `ro.virtual_ab.compression/userspace.snapshots` | 旧写法只开了构建宏，没把 `ro.virtual_ab.enabled` 带进 recovery prop.default，TWRP 运行时把本机当非 VAB |
| 18 | CI 克隆默认分支 | 复制 `${{ github.workspace }}` | 保证编的是被推送的 commit |
| 19 | CI 无 swap/JOBS 调优 | 8 GB swap + `JOBS=4` + `NINJA_HIGHMEM_NUM_JOBS=2` | 4 核 16 GB 上防 OOM |
| 20 | 无静态门禁 | `tools/check-tree.py` + CI 前置 | fstab/flag/布局错在编译前暴露 |

---

## 9. 参考

- TeamWin `android_bootable_recovery` / `android_system_vold` / `android_build`，分支 `android-12.1`
- minimal-manifest：`minimal-manifest-twrp/platform_manifest_twrp_aosp`，分支 `twrp-12.1`
- 内部移植手册：`twrp-porting` skill（`03` 目录结构、`04` BoardConfig、`05` TW 开关、`06` fstab/flags、
  `08` 镜像形态、`09` 解密、`17` CI）
- 事实与推导记录：`research/facts/device-facts.md`、`research/requirements.md`（研究用，不参与构建）
