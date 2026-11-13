#
# device/famue/bf61/BoardConfig.mk
# Famue BF61 — MT6762 (mt6765 BSP) · Android 12 · A/B · recovery-as-boot
#
# 所有硬件取值都来自本机 stock boot_a.img 的 v2 header / 分区转储（见 README「事实表」）：
#   page_size=2048  header_version=2  kernel=Image.gz (11,465,967 B)  dtb 段=101,729 B
#   base=0x40078000 kernel_offset=0x00008000 ramdisk_offset=0x11a88000
#   tags_offset=0x07808000 dtb_offset=0x07808000
#   boot=33,554,432 B  dtbo=8,388,608 B  vendor_boot=全零（本机不用它承载 recovery）
#
# 12.1 build/make 的生效规则（写错不报错、只静默失效）：
#   · BOARD_KERNEL_OFFSET / BOARD_RAMDISK_OFFSET / BOARD_TAGS_OFFSET / BOARD_DTB_OFFSET
#     不会自动变成 mkbootimg 参数 —— 必须显式写进 BOARD_MKBOOTIMG_ARGS；
#   · BOARD_BOOT_HEADER_VERSION 只决定「建不建 vendor_boot」，--header_version 也要自己传；
#   · BOARD_INCLUDE_DTB_IN_BOOTIMG 必须与 BOARD_PREBUILT_DTBIMAGE_DIR 成对出现。
#
DEVICE_PATH := device/famue/bf61

# ---------- minimal manifest 兼容 ----------
ALLOW_MISSING_DEPENDENCIES := true
BUILD_BROKEN_DUP_RULES := true
BUILD_BROKEN_MISSING_REQUIRED_MODULES := true

# ---------- 架构 ----------
TARGET_ARCH := arm64
TARGET_ARCH_VARIANT := armv8-a
TARGET_CPU_ABI := arm64-v8a
TARGET_CPU_ABI2 :=
TARGET_CPU_VARIANT := generic
TARGET_CPU_VARIANT_RUNTIME := cortex-a53

TARGET_2ND_ARCH := arm
TARGET_2ND_ARCH_VARIANT := armv7-a-neon
TARGET_2ND_CPU_ABI := armeabi-v7a
TARGET_2ND_CPU_ABI2 := armeabi
TARGET_2ND_CPU_VARIANT := generic
TARGET_2ND_CPU_VARIANT_RUNTIME := cortex-a53

# 64 位板子必须声明 app 位数支持，否则 board_config 直接报错
TARGET_SUPPORTS_32_BIT_APPS := true
TARGET_SUPPORTS_64_BIT_APPS := true

# ---------- 平台 / bootloader ----------
TARGET_BOARD_PLATFORM := mt6765
TARGET_BOOTLOADER_BOARD_NAME := mt6765
TARGET_NO_BOOTLOADER := true
BOARD_VENDOR := famue

# ---------- 内核（stock boot_a.img 原样提取，未重编） ----------
TARGET_PREBUILT_KERNEL := $(DEVICE_PATH)/prebuilt/kernel
BOARD_KERNEL_IMAGE_NAME := Image.gz
# 不要写 buildvariant=*：build/make 会自动追加 buildvariant=$(TARGET_BUILD_VARIANT)
BOARD_KERNEL_CMDLINE := bootopt=64S3,32N2,64N2 androidboot.selinux=permissive
BOARD_KERNEL_PAGESIZE := 2048
BOARD_KERNEL_BASE := 0x40078000
BOARD_BOOT_HEADER_VERSION := 2

# ---------- DTB / DTBO ----------
# prebuilt/dtb/mt6765.dtb 是 MTK 的单条 dt_table 容器（magic 0xd7b7ab1e，表内 1 条 FDT），
# 不是裸 FDT。build 端只做 `cat *.dtb > dtb.img`，mkbootimg 原样写进 v2 header 的 dtb 段。
BOARD_INCLUDE_DTB_IN_BOOTIMG := true
BOARD_PREBUILT_DTBIMAGE_DIR := $(DEVICE_PATH)/prebuilt/dtb
BOARD_PREBUILT_DTBOIMAGE := $(DEVICE_PATH)/prebuilt/dtbo.img
BOARD_DTBOIMG_PARTITION_SIZE := 8388608

# ---------- mkbootimg ----------
BOARD_MKBOOTIMG_ARGS += --header_version 2
BOARD_MKBOOTIMG_ARGS += --base $(BOARD_KERNEL_BASE)
BOARD_MKBOOTIMG_ARGS += --pagesize $(BOARD_KERNEL_PAGESIZE)
BOARD_MKBOOTIMG_ARGS += --kernel_offset 0x00008000
BOARD_MKBOOTIMG_ARGS += --ramdisk_offset 0x11a88000
BOARD_MKBOOTIMG_ARGS += --second_offset 0x00e88000
BOARD_MKBOOTIMG_ARGS += --tags_offset 0x07808000
BOARD_MKBOOTIMG_ARGS += --dtb_offset 0x07808000

# ---------- 分区 ----------
BOARD_FLASH_BLOCK_SIZE := 131072
BOARD_BOOTIMAGE_PARTITION_SIZE := 33554432

# super：5,112,119,296 B；group 与 super 差 1 MiB，留给 LP metadata
BOARD_SUPER_PARTITION_SIZE := 5112119296
BOARD_SUPER_PARTITION_GROUPS := main
BOARD_MAIN_PARTITION_LIST := system system_ext vendor product
BOARD_MAIN_SIZE := 5111070720
BOARD_USES_METADATA_PARTITION := true

# ---------- A/B ----------
# 必须写：TWRP 靠 -DAB_OTA_UPDATER 给 super 里的 dm 分区名补 _a/_b；
# 缺它时 Prepare_Super_Volume() 会拿裸名去找 dm 设备并死等（逻辑分区全灭）。
AB_OTA_UPDATER := true
AB_OTA_PARTITIONS += \
    boot \
    dtbo \
    system \
    system_ext \
    product \
    vendor \
    vbmeta \
    vbmeta_system

# ---------- 文件系统 ----------
TARGET_USERIMAGES_USE_EXT4 := true
TARGET_USERIMAGES_USE_F2FS := true
TARGET_USES_MKE2FS := true
BOARD_HAS_LARGE_FILESYSTEM := true
BOARD_SYSTEMIMAGE_FILE_SYSTEM_TYPE := ext4
BOARD_SYSTEM_EXTIMAGE_FILE_SYSTEM_TYPE := ext4
BOARD_VENDORIMAGE_FILE_SYSTEM_TYPE := ext4
BOARD_PRODUCTIMAGE_FILE_SYSTEM_TYPE := ext4
TARGET_COPY_OUT_SYSTEM_EXT := system_ext
TARGET_COPY_OUT_PRODUCT := product
TARGET_COPY_OUT_VENDOR := vendor

# ---------- recovery ----------
# 本机没有 recovery 分区：TWRP ramdisk 直接打进 boot.img，产物是 boot.img。
BOARD_USES_RECOVERY_AS_BOOT := true
TARGET_RECOVERY_PIXEL_FORMAT := "RGBX_8888"
RECOVERY_SDCARD_ON_DATA := true

# 单机型不写这行也会默认取 $(TARGET_DEVICE_DIR)/recovery/root；
# 显式写出来，将来拆 common 树时只需在后面追加 common 目录。
TARGET_RECOVERY_DEVICE_DIRS += $(DEVICE_PATH)
# 唯一一份分区表：build 会把它装到 ramdisk 的 system/etc/recovery.fstab，
# 同时作为依赖 —— 改 fstab 会触发 ramdisk 重建。
TARGET_RECOVERY_FSTAB := $(DEVICE_PATH)/recovery/root/system/etc/recovery.fstab

# ---------- 版本 / 安全补丁 ----------
PLATFORM_VERSION := 12
PLATFORM_VERSION_LAST_STABLE := $(PLATFORM_VERSION)
PLATFORM_SECURITY_PATCH := 2024-03-05
VENDOR_SECURITY_PATCH := $(PLATFORM_SECURITY_PATCH)
