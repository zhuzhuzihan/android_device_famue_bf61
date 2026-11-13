# BF61 TWRP 12.1 硬性需求提取（task-1 / guide-spec）

**图例**
- 无前缀路径 = 本仓库根 `/root/android_device_famue_bf61`（例 `BoardConfig.mk:51`）。
- `T:` = TWRP 12.1 只读源码 `/root/twrp-research/recovery-12.1`（`TeamWin/android_bootable_recovery` `android-12.1`）。
- `NN §x` = skill 文档 `/root/.dsh/skills/twrp-porting/references/NN-*.md` 的章节。
- **已由 Lead 确认、本文直接引用的事实**：A/B；recovery 嵌入 boot（无 recovery 分区）；`vendor_boot` 全零；dynamic partitions + super；FBE v2 `aes-256-xts:aes-256-cts:v2` + metadata 加密（`/dev/block/by-name/md_udc`）；stock fstab `first_stage_ramdisk/fstab.mt6762`；boot header v2 / pagesize 2048。
- 「源码裁决」= 文档与源码冲突时以源码为准（本文 §5）。

---

## 1 硬性要求（apply to: 12.1 + A/B recovery-as-boot + MT6762/6765 + dynamic partitions + FBEv2/metadata）

### 1.1 启动形态 / 镜像

| # | 要求 | 依据 |
|---|---|---|
| R1 | `BOARD_USES_RECOVERY_AS_BOOT := true`，构建目标 **`mka bootimage`**，产物 `out/target/product/bf61/boot.img`，`fastboot flash boot`。**不得**出现 `BOARD_RECOVERYIMAGE_PARTITION_SIZE`、不得用 `mka recoveryimage`。 | 08 §1 行②; 15 §3.1; `T:Android.mk:227-230`（自动 `TW_INCLUDE_REPACKTOOLS := true` + `-DBOARD_USES_RECOVERY_AS_BOOT`）; `T:data.cpp:809-814`（`tw_include_install_recovery_ramdisk=1`） |
| R2 | **`AB_OTA_UPDATER := true` 必写**，并补 `AB_OTA_PARTITIONS += boot system system_ext product vendor vbmeta vbmeta_system dtbo`。 | 15 §3.1 diff; `T:Android.mk:153-158`（`-DAB_OTA_UPDATER=1` + boot HAL 模块）; `T:data.cpp:798-802`; `T:partitionmanager.cpp:3562-3566`; `T:gui/libguitwrp_defaults.go:277`（只认字面 `"true"`） |
| R3 | 「有 vendor_boot 分区」**不等于**形态③。形态由 **boot header 版本**判定：header 2 ⇒ 形态②；header 3/4 ⇒ 形态③（`BOARD_MOVE_RECOVERY_RESOURCES_TO_VENDOR_BOOT`）。本机 header=2 且 vendor_boot 全零 ⇒ 禁止 header 3/4、禁止 `BOARD_MOVE_RECOVERY_RESOURCES_TO_VENDOR_BOOT`、禁止 `mka vendorbootimage`。 | 08 §1 行②③, 08 §2 (v2/v3) |
| R4 | 刷入后校验：`unpack_bootimg --boot_img boot.img` 必须复现 `header_version 2 / page size 2048 / cmdline / dtb size`。 | 08 §3 |
| R5 | 内核必须显式进 `$(PRODUCT_OUT)/kernel`（`LOCAL_KERNEL` + `PRODUCT_COPY_FILES += $(LOCAL_KERNEL):kernel`），因为 TeamWin build fork 无 `core/tasks/kernel.mk`，`TARGET_PREBUILT_KERNEL` 不被消费。**注**：该机制在 build/make，本 checkout 无法验证（见 §5-05）。 | 04 §2 ★; 15 §2.4 |
| R6 | `TW_INCLUDE_REPACKTOOLS` 无需手写（R1 自动开启）；但 repack 依赖 `/dev/block/bootdevice/by-name/*`（`T:twrpRepacker.cpp:316`），ramdisk 内必须存在 `/dev/block/bootdevice` 链接。 | 03 §4.1（`on fs` symlink 规则）; `T:twrpRepacker.cpp:316` |

### 1.2 内核 / boot header / dtb / dtbo

| # | 要求 | 依据 |
|---|---|---|
| R7 | header 版本变量正名是 **`BOARD_BOOT_HEADER_VERSION`**（不是 `BOARD_BOOTIMG_HEADER_VERSION`）。 | `T:Android.mk:174-176`（→ `-DBOARD_BOOT_HEADER_VERSION`）; `T:data.cpp:825-827`（→ `tw_boot_header_version`）; `T:twrpRepacker.cpp:140`（v4 分支用该值）; 04 §2 亦写 `BOARD_BOOT_HEADER_VERSION` |
| R8 | dtb 进 boot.img 的**文档路径**：`BOARD_INCLUDE_DTB_IN_BOOTIMG := true` + `BOARD_PREBUILT_DTBIMAGE_DIR := <目录>`（目录内是 `*.dtb`，build 拼接后 `--dtb`）。两者在 `bootable/recovery` 内 0 消费者（纯 build/make 变量）。 | 04 §2; 08 §2 v2 |
| R9 | `BOARD_KERNEL_PAGESIZE` 必须与 stock 一致（本机 2048）、`BOARD_KERNEL_BASE`/各 offset 必须与 stock 一致，否则 `fastboot` 报 `Bad image` 或黑屏。 | 04 §2「写错的症状」 |
| R10 | dtbo：`BOARD_PREBUILT_DTBOIMAGE` + `BOARD_DTBOIMG_PARTITION_SIZE`。`BOARD_INCLUDE_RECOVERY_DTBO` 只对「独立 recovery 映像」形态有意义，形态②下无意义（本 checkout 内亦 0 消费者）。 | 04 §2; 08 §1 行① |

### 1.3 fstab / flags 解析语义（全部源码级）

| # | 要求 | 依据 |
|---|---|---|
| R11 | 运行时 fstab 路径链固定：`/etc/twrp.fstab` → 不存在则 `/etc/recovery.fstab`。不要指望别的文件名。 | `T:twrp.cpp:390-396` |
| R12 | **分隔符逐行判定**：首字段 `/dev/` 或 `/devices/` ⇒ v2（`,`）；首字符**不是** `/`（裸逻辑分区名）⇒ 也判 v2（`,`，`block_device_index=0`）；以挂载点开头（`/data ...`）⇒ v1（`;`）。 | `T:partition.cpp:321-331`（判定）; `T:partition.cpp:1099-1102`（`source_separator`） |
| R13 | `/etc/twrp.flags` 的 flag **强制按 v1 解析**⇒ 只能用 `;`。写成 `,` 会被当成一个超长 flag，静默吞掉后续所有 flag。 | `T:partition.cpp:656`; 06 §1 |
| R14 | 合并优先级：主表行内的 flag 先应用（`T:partition.cpp:617-625`），`/etc/twrp.flags` 同挂载点的 flag 后应用并覆盖（`T:partition.cpp:648-659`）；`/etc/twrp.flags` 还能**覆写 v2 行的块设备**（`T:partition.cpp:416-431`）；主表没有的挂载点被追加（`T:partitionmanager.cpp:393-403`）。 | 06 §0（顺序描述有误，见 §5-01） |
| R15 | `/data` 与 `/metadata` 会被 **vendor fstab 二次替换**：`/vendor` 挂载后 TWRP 用 `fstab_suffix`/`hardware`/`hardware.platform` 去找 `/odm/etc/fstab.*`、`/vendor/etc/fstab.*`、`/system/etc/fstab.*`、`/first_stage_ramdisk/*`，找到就 `goto parse` 重解析，且第二趟 **`twrp_flags` 传 NULL**（设备树/`twrp.flags` 里的 `/data` 私有 flag 全部失效，只剩 vendor 行自身 + 挂载点默认值）。 | `T:twrp-functions.cpp:1567-1584`（查找路径）; `T:partitionmanager.cpp:409-427`（挂 /vendor → 找 → `goto parse`）; `T:partitionmanager.cpp:374`（`parse_userdata ? NULL : &twrp_flags`）; `T:partition.cpp:500-508`（/data 默认值） |
| R16 | 未识别 flag 的日志级别不同：v2 行内 flag 走 `LOGINFO`（`Display_Error=false`），v1 行 / `twrp.flags` 走 `LOGERR`。排障统一 `grep "Unhandled flag" /tmp/recovery.log`。 | `T:partition.cpp:625`; `T:partition.cpp:1173-1179` |

### 1.4 dynamic partitions / super

| # | 要求 | 依据 |
|---|---|---|
| R17 | super 存在性检测只看 `/dev/block/by-name/super` 是否 `access()` 成功——**不看 `ro.boot.dynamic_partitions`**。存在即 `Setup_Super_Devices()`（`CreateLogicalPartitions`）。 | `T:partitionmanager.cpp:3661-3663`; `T:partitionmanager.cpp:273-275`; `T:partitionmanager.cpp:3621-3624` |
| R18 | 逻辑分区条目必须带 `logical` flag（→ `Is_Super=true`），随后由 `Prepare_Super_Volume()` 接管：块设备被**覆盖**为 dm 设备、`Can_Be_Backed_Up/Can_Be_Wiped` 被强制置 false。 | `T:partition.cpp:1064-1066`; `T:partitionmanager.cpp:377`; `T:partitionmanager.cpp:3554-3596` |
| R19 | `Prepare_Super_Volume()` 的 dm 分区名带 slot 后缀，**仅当 `AB_OTA_UPDATER` 已定义**；否则用裸名 → `fs_mgr_update_logical_partition()` 失败（分区被丢弃）或后续 `while (access(...) != 0) usleep(100)` 死等。⇒ R2 是动态分区可用性的前置条件。 | `T:partitionmanager.cpp:3562-3566`; `T:partitionmanager.cpp:3576-3583` |
| R20 | `/super` 条目由 TWRP 自己生成（`Setup_Super_Partition()` + `Add_Partition()` 直接 `push_back`，无去重）⇒ 手写 `/super` 行会产生重复条目。 | `T:partitionmanager.cpp:549-550`; `T:partitionmanager.cpp:3626-3658`; `T:partitionmanager.cpp:3485-3487` |

### 1.5 FBEv2 + metadata 加密

| # | 要求 | 依据 |
|---|---|---|
| R21 | 只需 `TW_INCLUDE_CRYPTO := true`；`TW_INCLUDE_FBE`、`TW_INCLUDE_FBE_METADATA_DECRYPT`、`TW_INCLUDE_CRYPTO_FBE`（make 变量）都**不必手写**——`-DTW_INCLUDE_FBE`、`-DTW_INCLUDE_FBE_METADATA_DECRYPT`、`-DUSE_FSCRYPT` 在 crypto 段内无条件加入。 | `T:Android.mk:335-358`（339 强制 `TW_INCLUDE_CRYPTO_FBE := true`；340 `-DTW_INCLUDE_FBE`；358 `-DTW_INCLUDE_FBE_METADATA_DECRYPT`） |
| R22 | `/data` 行必须同时给三个 flag：`fileencryption=<contents>:<filenames>`（→ `fbe.contents`/`fbe.filenames`）、`metadata_encryption=<contents>:<filenames>`（→ `metadata.contents`/`metadata.filenames`，FBEv2 metadata 解密必需）、`keydirectory=<dir>`（→ `Key_Directory`）。 | `T:partition.cpp:956-974`; `T:partition.cpp:976-994`; `T:partition.cpp:1066-1071` |
| R23 | `Key_Directory` 非空 ⇒ `Is_Encrypted=true`、`Is_FBE=true`，`/data` 不尝试直接挂载，必须走 `Decrypt_Data()`（先挂 `Key_Directory` 的 root path 对应分区，再 `fscrypt_mount_metadata_encrypted()`）。 | `T:partition.cpp:710-713, 766-777`; `T:partitionmanager.cpp:585-615` |
| R24 | 因此 `/metadata` 必须单独成条且可挂（`Find_Partition_By_Path()` 用 `Get_Root_Path()` 把 `/metadata/vold/...` 归约到 `/metadata`）。 | `T:partitionmanager.cpp:591-596`; `T:partitionmanager.cpp` `Find_Partition_By_Path` |
| R25 | `metadata.*` / `fbe.*` 属性在本 checkout 内**只有写、没有读**（消费者在 vold/MetadataCrypt，属 manifest 外部仓库）⇒ 无法在本 checkout 证明「缺 `metadata_encryption=` 必失败」，但缺它时属性根本不会被 set。 | `T:partition.cpp:963-992`（全仓 grep 无 consumer） |
| R26 | 解密依赖 `/vendor` 已挂载 + vendor manifest 里能查到的 keymaster 服务（`Get_Service_From_Manifest("/vendor", "android.hardware.keymaster")`）。 | `T:partitionmanager.cpp:220-233, 409-412`; 03 §4.4 |

### 1.6 ramdisk 文件放置（决定「改了没生效」）

| # | 要求 | 依据 |
|---|---|---|
| R27 | `recovery/root/` 整目录 cp 进 ramdisk；单机型默认取 `$(TARGET_DEVICE_DIR)/recovery/root`，**不写** `TARGET_RECOVERY_DEVICE_DIRS` 也生效；有 common 树才写，且只写到 device 目录（不带 `/recovery/root`）。该实现位于 TeamWin 的 build/make fork，`bootable/recovery` 内 0 命中。 | 03 §3; 15 §2.4 注释 |
| R28 | 运行时 `/etc` 是 `/system/etc` 的符号链接 ⇒ ramdisk 内**不能存在真实 `/etc` 目录**（否则 `symlink` 失败，`/etc/twrp.flags` 等全部走偏）。TWRP 私有文件放 `recovery/root/system/etc/`。 | `T:etc/init.rc:36`; 03 §3 结论3; 03 §4.3; 15 §2.8 |
| R29 | `init.recovery.<ro.hardware>.rc` 文件名必须等于 `getprop ro.hardware`，否则永不加载且无报错。 | `T:etc/init.rc:7`; 03 §4.1 |
| R30 | `PRODUCT_COPY_FILES` 目标只能用 `$(TARGET_COPY_OUT_RECOVERY)/root/...`；绝对路径 `TARGET_RECOVERY_ROOT_OUT` 只能在 `Android.mk` 的 `LOCAL_MODULE_PATH` 用。 | 03 §2.3; 15 §2.3 |
| R31 | `TARGET_RECOVERY_FSTAB` 应指向**唯一一份** fstab（15 的模板指向 `recovery/root/system/etc/recovery.fstab`，避免「BoardConfig 一份 + ramdisk 一份」漂移）。该变量在 `bootable/recovery` 内 0 消费者（build/make 负责拷贝）。 | 04 §7; 15 §2.4 |
| R32 | 定义 `TARGET_RECOVERY_INITRC` 会自动置 `TW_EXCLUDE_DEFAULT_USB_INIT := true`（本机未用该变量，走的是 `recovery/root/init.recovery.mt6762.rc` + 手动置 true，等价）。 | `T:Android.mk:420-422` |

---

## 2 BoardConfig / `TW_*` 变量表（必需 / 可选 / 禁止 + 精确语义）

判定语义三类（源码原文）：
- `ifeq ($(X),true)`：只认字面 `true`。
- `ifneq ($(X),)`：**任何非空值**都生效（写 `false` 也开）。
- `ifneq ($(X),true)`：**除 `true` 以外都生效**（写 `false` 反而开）。
- Soong 侧（`gui/libguitwrp_defaults.go`）：只认字面 `"true"`。

### 2.1 必需（缺了直接不出包 / 不出分区）

| 变量 | 值 | 判定 | 源码证据 | 放置 |
|---|---|---|---|---|
| `BOARD_USES_RECOVERY_AS_BOOT` | `true` | `ifeq(...,true)` | `T:Android.mk:227-230` | BoardConfig |
| `AB_OTA_UPDATER` | `true` | `ifeq(...,true)` + go `=="true"` | `T:Android.mk:153`; `T:gui/libguitwrp_defaults.go:277`; `T:partitionmanager.cpp:3562` | BoardConfig |
| `BOARD_BOOT_HEADER_VERSION` | `2` | `ifneq(...,)` | `T:Android.mk:174-176`; `T:data.cpp:825` | BoardConfig |
| `TW_INCLUDE_CRYPTO` | `true` | `ifeq(...,true)` | `T:Android.mk:335`; `T:etc/Android.mk:184`; `T:libtar/Android.mk:16` | BoardConfig |
| `TARGET_PREBUILT_KERNEL` + 拷贝到 `$(PRODUCT_OUT)/kernel` | 路径 | build fork | 04 §2（本 checkout 不可验证） | BoardConfig + device.mk |
| `TARGET_RECOVERY_FSTAB` | 单一路径 | build/make | `T:twrp.cpp:390-396`（运行时只看 `/etc/*`） | BoardConfig |
| `ALLOW_MISSING_DEPENDENCIES` | `true` | — | skill 硬性注意（`vendorsetup.sh` 里 `export`） | **vendorsetup.sh**（本机缺失，见 §4） |
| `COMMON_LUNCH_CHOICES` 含 `twrp_bf61-eng` | — | — | skill 硬性注意 `lunch` | `AndroidProducts.mk` |

### 2.2 可选 / 推荐（语义已核对）

| 变量 | 本机值 | 判定 | 说明（源码） |
|---|---|---|---|
| `TW_THEME` | `portrait_mdpi` | go `getMakeVars` | 主题目录存在性：`T:gui/theme/portrait_mdpi` ✓（`T:gui/libguitwrp_defaults.go:187-231`） |
| `TW_EXTRA_LANGUAGES` | `false` | go `== "true"` | 只有字面 `true` 才加 extra-languages 目录（`T:gui/libguitwrp_defaults.go:241`） |
| `TW_PREPARE_DATA_MEDIA_EARLY` | `true` | `ifeq(...,true)` | `T:Android.mk:195-197` → `T:partition.cpp:692, 1275` |
| `TW_NO_BIND_SYSTEM` | `true` | `ifeq(...,true)` | `T:Android.mk:187-189` |
| `TW_USE_TOOLBOX` | `true` | 被 `T:Android.mk:219-222` 二次赋值 | 若设 `TW_SYSTEM_BUILD_PROP_ADDITIONAL_PATHS` 会被强改 false；`etc/Android.mk:214` 装 `init.recovery.mksh.rc` |
| `TWRP_INCLUDE_LOGCAT` + `TARGET_USES_LOGD` | 都 `true` | `ifeq(...,true)` 双层 | `T:etc/Android.mk:199-212` 装 `init.recovery.logd.rc`；缺任一个就不装 |
| `TW_INCLUDE_RESETPROP` / `TW_INCLUDE_LIBRESETPROP` | 都 `true` | `ifeq(...,true)` / `ifneq(...,)` | `T:Android.mk:538-545`; `T:prebuilt/Android.mk:527` |
| `TW_INCLUDE_NTFS_3G` | `true` | `ifeq(...,true)` | `T:prebuilt/Android.mk:340`; `T:Android.mk:619` |
| `RECOVERY_SDCARD_ON_DATA` | `true` | **`ifneq(...,)`** | `T:Android.mk:245-247`（写 `false` 也照样开）→ `datamedia` → `/data` 自动成 storage/settingsstorage（`T:partition.cpp` `Setup_Data_Media`） |
| `TW_EXCLUDE_DEFAULT_USB_INIT` | `true` | **`ifneq(...,true)`** | `T:etc/Android.mk:17`（写 `false` 会**保留**默认 usb rc） |
| `TW_EXCLUDE_NANO` / `TW_EXCLUDE_BASH` | 都 `true` | `ifeq(...,true)` + `ifneq(...,true)` 混用 | 需两边都命中，只能写字面 `true`（`T:Android.mk:447`; `T:prebuilt/Android.mk:403,410`） |
| `TW_MAX_BRIGHTNESS` / `TW_DEFAULT_BRIGHTNESS` / `TW_BRIGHTNESS_PATH` | 255 / 128 / 路径 | `ifneq(...,)` | `T:Android.mk:378-390`（值里的引号会原样进 `-D`） |
| `TARGET_RECOVERY_PIXEL_FORMAT` | `"RGBX_8888"` | minui 注释块（当前以 `TARGET_RECOVERY_PIXEL_FORMAT` 宏直传） | 04 §7 |
| `BOARD_USES_METADATA_PARTITION` | `true` | build/make | `bootable/recovery` 内 0 消费者；真正决定 `/metadata` 的是 fstab 条目 |
| `BOARD_HAS_LARGE_FILESYSTEM` | `true` | build/make | 同上，0 消费者 |
| `BUILD_BROKEN_DUP_RULES` / `BUILD_BROKEN_ELF_PREBUILT_PRODUCT_COPY_FILES` | `true` | build/make | 04 §8 破窗变量 |
| `PLATFORM_VERSION` / `PLATFORM_SECURITY_PATCH` | `12` / `2024-03-01` | — | 04 §8（模板用 `99.x` + `2099-12-31` 伪装；本机取真实值亦可，只要不低于 blob 断言） |

### 2.3 禁止 / 无效（写了不报错但不生效，或语义反了）

| 变量 | 状态 | 证据 |
|---|---|---|
| `TW_HAS_NO_RECOVERY_PARTITION` | **0 消费者**（12.1 已无此开关） | 全仓 grep 0 命中 |
| `TW_EXCLUDE_TWRPAPP` | **0 消费者**（不再内建 TWRP app） | 全仓 grep 0 命中 |
| `TW_SCREEN_BLANK_ON_BOOT` | 仅 `T:gui/gui.cpp:763` 一个 `#ifdef`，**没有任何 `-D` 发射点** ⇒ make 变量写死也不会生效 | 全仓 grep：只有 gui.cpp |
| `BOARD_BOOTIMG_HEADER_VERSION` | **0 消费者**（正名见 R7） | 全仓 grep 0 命中 |
| `TARGET_PREBUILT_DTB` | **0 消费者**（正名见 R8） | 全仓 grep 0 命中 |
| `BOARD_RECOVERYIMAGE_PARTITION_SIZE` | 形态②下无用 | 08 §1 |
| `BOARD_MOVE_RECOVERY_RESOURCES_TO_VENDOR_BOOT` | 本机（header 2 + vendor_boot 全零）**禁止** | 08 §1 行③, 08 §2 |
| `TARGET_RECOVERY_DEVICE_DIRS` 指向 `.../recovery/root` | 错写会得到 `recovery/root/recovery/root/...` | 03 §3 结论2 |
| `TW_EXCLUDE_APEX` 写 `false` | **仍会排除 APEX**（`ifeq ($(TW_EXCLUDE_APEX),)` ⇒ 非空即排除） | `T:Android.mk:76-81` |
| `TARGET_RECOVERY_ROOT_OUT` 进 `PRODUCT_COPY_FILES` | 报 `Cannot copy ... to absolute path` | 03 §2.3 |

---

## 3 构建目标与镜像布局（本机形态）

| 项 | 值 | 依据 |
|---|---|---|
| 形态 | ② recovery-as-boot（A/B，header 2，无 recovery 分区） | 08 §1 行②; Lead 事实 |
| 构建目标 | `mka bootimage -j$(nproc)` | 08 §1; 15 §3.1 |
| 产物 | `out/target/product/bf61/boot.img` | 08 §3 |
| 刷入 | `fastboot flash boot boot.img`（必要时先 `fastboot --set-active=a`），先 `fastboot boot boot.img` 验证 | 08 §4; 15 §3.1 |
| 校验 | `unpack_bootimg --boot_img out/.../boot.img --out unpacked/` → 看 `bootimg_info`：`header_version 2`、`page size 2048`、cmdline、`dtb size` | 08 §3 |
| **不要** | `mka recoveryimage` / `mka vendorbootimage` / header 3-4 / `BOARD_MOVE_RECOVERY_RESOURCES_TO_VENDOR_BOOT` | 08 §1, §2 |

### 3.1 内核 / dtb / dtbo 变量拼写对照（任务点 3 的精确答案）

| 指南/正确拼写 | 是否被 12.1 树消费 | 本仓库现状 |
|---|---|---|
| `BOARD_BOOT_HEADER_VERSION` | ✅ `T:Android.mk:174-176`（`-D`）、`T:data.cpp:825`（`tw_boot_header_version`）、`T:twrpRepacker.cpp:140` | ❌ 仓库用 `BOARD_BOOTIMG_HEADER_VERSION`（`BoardConfig.mk:51`），仅靠 `BoardConfig.mk:61` 的 `--header_version` 透传才让镜像正确 |
| `BOARD_BOOTIMG_HEADER_VERSION` | ❌ 0 消费者 | 仓库在用（`BoardConfig.mk:51`） |
| `BOARD_PREBUILT_DTBIMAGE_DIR` | ⚠ build/make 变量（本 checkout 0 命中） | 未使用 |
| `TARGET_PREBUILT_DTB` | ❌ 0 消费者 | 仓库在用（`BoardConfig.mk:39`）+ `--dtb`（`:42`） |
| `BOARD_INCLUDE_DTB_IN_BOOTIMG` | ⚠ build/make 变量 | ❌ 未设置（dtb 靠 `--dtb` 透传进镜像） |
| `BOARD_PREBUILT_DTBOIMAGE` | ⚠ build/make 变量 | ✅ `BoardConfig.mk:52` |
| `BOARD_INCLUDE_RECOVERY_DTBO` | ⚠ build/make 变量，形态②无意义 | 未使用（正确） |
| `BOARD_KERNEL_IMAGE_NAME` / `BOARD_KERNEL_PAGESIZE` / `BOARD_KERNEL_BASE` / `*_OFFSET` | ✅ 经 `BOARD_MKBOOTIMG_ARGS` 透传给 mkbootimg | ✅ `BoardConfig.mk:40,44-50` |

> 结论：**`BOARD_BOOT_HEADER_VERSION` 必须补齐**（`BOARD_BOOTIMG_HEADER_VERSION` 是死变量）；dtb 用 `--dtb` 直传是可用路径（mkbootimg 透传），但和 08/04 的文档路径（`BOARD_INCLUDE_DTB_IN_BOOTIMG` + `BOARD_PREBUILT_DTBIMAGE_DIR`）不是一套，二选一并写进 README，避免下次改动踩双轨。

---

## 4 当前仓库违规清单（file:line）

| # | 位置 | 问题 | 依据 | 后果 |
|---|---|---|---|---|
| V1 | `BoardConfig.mk`（全文） | 缺 `AB_OTA_UPDATER := true`（及 `AB_OTA_PARTITIONS`） | R2; 15 §3.1 | `-DAB_OTA_UPDATER` 不生效 → `system/system_ext/vendor/product` 的 dm 名不带 `_a` → `Prepare_Super_Volume` 失败或死等 ⇒ **逻辑分区全灭 / 卡启动** |
| V2 | `BoardConfig.mk:51` | `BOARD_BOOTIMG_HEADER_VERSION := 2` 是死变量 | R7 | `tw_boot_header_version` 未定义；repack（备份/刷 boot）拿不到 header 版本；靠 `:61` 透传才没炸 |
| V3 | `BoardConfig.mk:66` | `TW_HAS_NO_RECOVERY_PARTITION := true` 无消费者 | §2.3 | 无效，误导后续维护者（以为靠它表达「无 recovery 分区」） |
| V4 | `BoardConfig.mk:139` | `TW_EXCLUDE_TWRPAPP := true` 无消费者 | §2.3 | 无效 |
| V5 | `BoardConfig.mk:107` | `TW_SCREEN_BLANK_ON_BOOT := true` 无 `-D` 发射点 | §2.3 | 完全无效（想去掉开机黑屏要另找路径） |
| V6 | `BoardConfig.mk:114` | `TW_DISABLE_TTF := false` **语义反了**：`ifneq(...,true)` ⇒ TTF **被包含**，与 `:111-112` 注释「TTF 可砍」矛盾 | `T:prebuilt/Android.mk:325` | 白占体积（要砍写 `true`） |
| V7 | `BoardConfig.mk:67` | `TW_EXCLUDE_APEX := true` 在 Android 12 上砍掉 `/apex` 加载（`partitionmanager.cpp:482,1771,3732` 走 `#ifdef TW_EXCLUDE_APEX` 分支） | 05 §6 建议 Android 10+ 保留 | 若 keymaster/gatekeeper 或运行时库来自 apex 则解密链断；属高风险取舍，需体积理由才保留 |
| V8 | `BoardConfig.mk:119` | `TW_INCLUDE_NTFS_3G := true` + `TW_EXCLUDE_NANO/BASH` 组合：NTFS-3G 与 exFAT/fuse 都吃体积，与 `:111-112`「32MB 装不下」的诉求冲突（取舍项，非硬错） | 05 §6 体积表 | 体积风险 |
| V9 | `recovery/root/etc/recovery.fstab`（整文件，与根 `recovery.fstab` 逐字节重复） | 在 ramdisk 里创建**真实 `/etc` 目录**，覆盖 `symlink /system/etc /etc` | R28; `T:etc/init.rc:36` | `/etc/twrp.flags`、`/etc/twrp.fstab` 等全部走偏；`symlink` 失败仅在内核日志可见 |
| V10 | `recovery.fstab:14` / `recovery/root/etc/recovery.fstab:14` | `/data` 缺 `metadata_encryption=`（只有 `fileencryption=`、`keydirectory=`） | R22 | `metadata.*` 属性不会被 set；FBEv2 metadata 解密链缺一环（若 vendor fstab 被成功导入则可被兜底，见 V15） |
| V11 | 仓库根 | **完全没有 `twrp.flags`**（全部私有 flag 写在 `recovery.fstab` 行内） | 06 §3.5; 15 §2.8 | 与 V15 叠加后 `/data`、`/metadata` 的私有 flag 在第二趟解析里丢失；也无法单独维护 flag |
| V12 | 仓库根 | 缺 `vendorsetup.sh`（其中应 `export ALLOW_MISSING_DEPENDENCIES=true`） | skill 硬性注意; 15 §2.5 | minimal manifest 下 `lunch` 可能直接失败（`BoardConfig.mk:7` 的 `ALLOW_MISSING_DEPENDENCIES := true` 时机太晚，不能替代） |
| V13 | 仓库根 | 缺 `system.prop`（MTK 需要的 `ro.board.platform=mt6765`、`sys.usb.controller=musb-hdrc`、`ro.crypto.*` / `vendor.gatekeeper.disable_spu` 一类） | 03 §2.4; 15 §2.6 | 属性散落在 `device.mk:11-15` 的 `PRODUCT_PROPERTY_OVERRIDES`，缺 recovery 侧覆盖能力 |
| V14 | `BoardConfig.mk:38-42` | 内核拷贝缺失：无 `LOCAL_KERNEL` + `PRODUCT_COPY_FILES += ...:kernel` | R5; 04 §2 ★ | 按文档，`mka bootimage` 在 link 阶段报 `No rule to make target 'out/target/product/bf61/kernel'`（build fork 行为，本 checkout 不可验证） |
| V15 | `recovery.fstab:5-8` + `BoardConfig.mk:78-81` | 逻辑分区源列写裸名（`system /system ...`）——**格式合法**（v2，逗号），但依赖 `AB_OTA_UPDATER`（V1）才生效；同时行内 `avb=`/`first_stage_mount` 是无消费者 flag（只打 INFO） | R12, R19 | 修好 V1 后可用；`avb=`/`first_stage_mount` 属噪音（不影响功能） |
| V16 | `recovery.fstab:28` | 手写 `/super` 条目，而 TWRP 会自己生成（`Setup_Super_Partition` + `push_back` 无去重） | R20 | `/super` 重复条目（备份/挂载列表出现两次） |
| V17 | `recovery.fstab:31-32` | `/dev/block/by-name/nvdata`、`nvcfg` 与 `:19-20` 同一块设备被两条条目占用（一条 ext4、一条 emmc image），且都带 `formattable` | 06 §2.2 | 误格式化风险；TWRP 列表重复 |
| V18 | `recovery.fstab` | 缺 `/dtbo`、`/vbmeta`、`/vbmeta_system`、`/vendor_boot` 条目（`prebuilt/dtbo.img`、`BOARD_DTBOIMG_PARTITION_SIZE` 已有） | 06 §3.2/§3.3 模板; 08 §1 | TWRP 内无法备份/刷 dtbo、vbmeta（A/B + AVB 机型禁用校验时必需） |
| V19 | `recovery/root/init.recovery.mt6762.rc`（整文件） | 无 `on fs` 段创建 `/dev/block/bootdevice` 链接（`fstab` 用 `/dev/block/by-name` 暂时绕过，但 repack 与 super 符号链接要 bootdevice） | R6; 03 §4.1 | repack / `Install Recovery Ramdisk` 可能找不到 boot 分区；`Prepare_Super_Volume` 的 symlink 静默失败 |
| V20 | `recovery/root/init.recovery.mt6762.rc:14-27` | keymaster/gatekeeper service 无 `disabled` 也无 `start`，靠 init class 默认启动；且二进制在 `/vendor/bin`（依赖 `/vendor` 已挂载） | R26; 15 §2.9 注 | 可能「init 报 unable to start」或启动顺序不对；需 `adb shell ps` 验证是否真在跑 |
| V21 | `.github/workflows/build.yml:21,57` | `actions/checkout@v4` 检出后又 `git clone` 远端树（本次修改不会进 CI 构建）；`:45` 用 `--depth=1` + `:51` `-j4`；无 ccache、无 swap/JOBS 调优 | 17 §0.5 | CI 编的不是被检出的树；4 核 + 12 GB 上 `mka` 易 OOM |
| V22 | `.github/workflows/build.yml:65-67` | `source build/envsetup.sh` 前无 `set +u` 保护 | skill 硬性注意 | 若 CI 打开 `set -u` 会直接杀掉 envsetup |

---

## 5 文档 vs 源码（source wins）

| # | 文档说法 | 源码裁决 | 对写文件的影响 |
|---|---|---|---|
| 5-01 | 06 §0：合并顺序「**先**读 `/etc/recovery.fstab` 暂存 flag，**再**读 `/etc/twrp.flags`」 | **反了**：`Process_Fstab()` 第一件事就是打开 `/etc/twrp.flags` 建 map（`T:partitionmanager.cpp:272`），之后才打开主表（`:336`）。覆盖效果（twrp.flags 胜）与文档结论一致 | 结论不受影响；但别据此推断「twrp.flags 里的块设备会被主表覆盖」——**twrp.flags 的块设备会覆盖主表**（`T:partition.cpp:416-431`） |
| 5-02 | 06 §0：未识别 flag → `/tmp/recovery.log` 打 `Unhandled flag` | 分级不同：v2 行内 flag 是 `LOGINFO`，v1 行 / `twrp.flags` 才 `LOGERR`（`T:partition.cpp:625,1173-1179`） | 排障时不要只看 ERROR；`grep "Unhandled flag"` 两级都要抓 |
| 5-03 | 03 §4.3：「同目录 `recovery.fstab` 是 AOSP 五列格式（**第一段挂载点**）」 | AOSP 五列第一段是 **source**（`/dev/...`），挂载点是第二段（`T:partition.cpp:321-331` 据此判 v2）；15 §2.7 写的 `<src> <mnt_point> <type> <mnt_flags> <fs_mgr_flags>` 才是对的 | 写 `recovery.fstab` 时第一列**必须**是块设备，写成挂载点会被判成 v1 而分隔符变 `;` |
| 5-04 | 06 §0 未提 | **vendor fstab 二次替换**：`/vendor` 挂载后按 `fstab_suffix`/`hardware`/`hardware.platform` 找 `/vendor/etc/fstab.mt6762` 等，命中就重解析 `/data`、`/metadata` 且 `twrp_flags=NULL`（`T:twrp-functions.cpp:1567-1584`; `T:partitionmanager.cpp:409-427, 374`） | 设备树里 `/data` 的 TWRP 私有 flag **只在第一趟有效**；`/data` 的加密 flag 实际以 vendor 行为准 ⇒ `/data` 三条 crypto flag 必须与 stock 完全一致，且 `twrp.flags` 不要指望能补 `/data` |
| 5-05 | 04 §2 ★ / 15 §2.4：TeamWin build fork 无 `core/tasks/kernel.mk`，`TARGET_PREBUILT_KERNEL` 不被消费 | 本 checkout 只有 `bootable/recovery`，**无法验证**（build/make 不在） | 按文档执行（多写一次拷贝零成本）；但别把它当「源码已验证」结论 |
| 5-06 | 05 §0/§1 把 `TW_SCREEN_BLANK_ON_BOOT` 列为可用开关 | 12.1 无 `-D` 发射点，`#ifdef` 永不成立（`T:gui/gui.cpp:763`） | 别靠它关开机黑屏 |
| 5-07 | 05 §6：`TW_EXCLUDE_APEX := true` =「不编译 twrpApex.cpp」 | 判据是 `ifeq ($(TW_EXCLUDE_APEX),)`（`T:Android.mk:76`）⇒ **任何非空值**都排除，写 `false` 也排除 | 要保留 APEX 必须**整行删除**，不能写 `false` |
| 5-08 | 05 §0「加密」行：`TW_INCLUDE_FBE` / `TW_INCLUDE_FBE_METADATA_DECRYPT` 写不写都一样 | **正确**：`-DTW_INCLUDE_FBE`、`-DTW_INCLUDE_FBE_METADATA_DECRYPT`、`-DUSE_FSCRYPT` 在 `TW_INCLUDE_CRYPTO=true` 段内无条件加入（`T:Android.mk:340,358`） | 只需 `TW_INCLUDE_CRYPTO := true`；`TW_INCLUDE_FBE_METADATA_DECRYPT` 写了也无害 |
| 5-09 | 04 §7：定义 `TARGET_RECOVERY_INITRC` 会自动置 `TW_EXCLUDE_DEFAULT_USB_INIT := true` | **正确**（`T:Android.mk:420-422`） | — |
| 5-10 | 06 §2.5 / 15 §3.1：`slotselect` 自动加 `_a/_b`，「路径已带后缀再加会变成 `system_a_a`」 | 源码是**存在性判断**而非拼接盲加：`Path_Exists(Primary_Block_Device + suffix)` 成功才改（`T:partition.cpp:3208-3211`），并顺手 `unlink`+`symlink` 造一个不带后缀的兼容链接 | 路径带后缀时 `slotselect` 因 `system_a_a` 不存在而**静默无效**（不会崩），但 `unlink(Primary_Block_Device)` 那步要留意指向 |
| 5-11 | 05 §5：`TW_HAS_NO_BOOT_PARTITION` 可用 | **正确**（`T:data.cpp:739`）；但 12.1 没有 `TW_HAS_NO_RECOVERY_PARTITION` | 想表达「无 recovery 分区」只能靠 `BOARD_USES_RECOVERY_AS_BOOT` |
| 5-12 | 06 §3.3：逻辑分区行写 `/dev/block/mapper/system` | 块设备列最终会被 `Prepare_Super_Volume()` 覆盖（`T:partitionmanager.cpp:3585-3586` `Set_Block_Device`），所以在 `logical` 行里写 by-name 裸名也能工作（前提是 `AB_OTA_UPDATER`，R19） | 源列写裸名（本仓库写法）在修好 V1 后合法；不必强改成 `/dev/block/mapper/*` |

---

## 6 Must-fix list（≤12，按优先级）

1. **`BoardConfig.mk`：补 `AB_OTA_UPDATER := true` + `AB_OTA_PARTITIONS += boot system system_ext product vendor vbmeta vbmeta_system dtbo`**（V1/R2/R19）——否则 dynamic partitions 全灭或启动死等。
2. **`BoardConfig.mk:51` 改名为 `BOARD_BOOT_HEADER_VERSION := 2`**，并同步 `:61` 的 `--header_version` 引用（V2/R7）。
3. **删掉 `recovery/root/etc/recovery.fstab`**，fstab 只留一份：`recovery/root/system/etc/recovery.fstab`，并让 `BoardConfig.mk:70` 的 `TARGET_RECOVERY_FSTAB` 指向它（V9/V10/R28/R31）。
4. **新增 `recovery/root/system/etc/twrp.flags`**（`;` 分隔），把 TWRP 私有 flag 从 `recovery.fstab` 行内搬出（V11/R13/R14）。
5. **`/data` 行补 `metadata_encryption=aes-256-xts:wrappedkey_v0`**（值与 stock `fstab.mt6762` 逐字一致），并与 `fileencryption=`、`keydirectory=` 三者齐备（V10/R22；注意 §5-04 二次替换）。
6. **新增 `vendorsetup.sh`**（`export ALLOW_MISSING_DEPENDENCIES=true`）（V12）。
7. **`BoardConfig.mk` 修正语义反了的开关**：`TW_DISABLE_TTF := true`（当前 `false` 等于保留 TTF，V6）；`TW_EXCLUDE_APEX` 决策（要保留就整行删，不能写 `false`，V7）。
8. **删除死变量**：`TW_HAS_NO_RECOVERY_PARTITION`、`TW_EXCLUDE_TWRPAPP`、`TW_SCREEN_BLANK_ON_BOOT`、`BOARD_BOOTIMG_HEADER_VERSION`、`TARGET_PREBUILT_DTB`（随 V2/R8 一并换正名）（V3/V4/V5）。
9. **`recovery/root/init.recovery.mt6762.rc` 补 `on fs` 段的 `/dev/block/bootdevice` 链接**（真实平台路径以 `ls -l /dev/block/platform` 为准）（V19/R6）。
10. **删手写 `/super` 条目；把重复块设备的 `nvdata`/`nvcfg` 合并成一条**（V16/V17/R20）。
11. **补 `/dtbo`、`/vbmeta`、`/vbmeta_system` 条目**（`flashimg=1`/`backup=1`，A/B 下不加 `slotselect` 除非确认 by-name 是裸名）（V18）。
12. **补内核落盘（`LOCAL_KERNEL` + `PRODUCT_COPY_FILES += $(LOCAL_KERNEL):kernel`）与 `system.prop`**；CI 改为构建检出树本身并加 `set +u` 保护（V14/V13/V21/V22）。

> 未列入 must-fix 但需上机验证的三条：`/vendor/etc/fstab.mt6762` 是否真存在（决定 §5-04 是否触发，`grep "Fstab: " /tmp/recovery.log`）；`/dev/block/by-name` 里 `boot` 是否存在（还是只有 `boot_a/boot_b`，影响 `slotselect`）；TWRP 内 keymaster/gatekeeper service 是否真在跑（`ps -A | grep -E "gatekeeper|keymaster"`）。
