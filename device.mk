#
# device/famue/bf61/device.mk
# 产品级配置：内核落盘、TWRP 开关、system.prop、动态分区。
#
# ★ 所有 TW_* 只写在本文件（唯一一处）。
#   同一个开关在 BoardConfig 与 device.mk 各写一份是"改了没生效"的经典来源；
#   真实 TWRP 树（twrp_sweet 等）的惯例就是把 TW_* 放 device.mk。
#
LOCAL_PATH := device/famue/bf61

# TeamWin build fork 不带 core/tasks/kernel.mk，TARGET_PREBUILT_KERNEL 不会被消费。
# 不显式拷到 $(PRODUCT_OUT)/kernel，bootimage 链接阶段会报
# "No rule to make target out/target/product/bf61/kernel"。
LOCAL_KERNEL := $(LOCAL_PATH)/prebuilt/kernel
PRODUCT_COPY_FILES += $(LOCAL_KERNEL):kernel

# super 里的逻辑分区（TWRP 需要 liblp）
PRODUCT_USE_DYNAMIC_PARTITIONS := true

# Virtual A/B（stock 为真 VAB：ro.virtual_ab.enabled=true + userspace snapshots）。
# TWRP 运行时靠 ro.virtual_ab.enabled 判定 VAB 行为：
#   · Format Data 前 Check_Pending_Merges()（partitionmanager.cpp:1770）
#   · OTA zip 安装后重映射 super（twinstall.cpp:344）
#   · 重启询问逻辑（recovery.cpp:322）与 tw_virtual_ab UI 状态（data.cpp:840）
# 缺这个属性 TWRP 会把本机当非 VAB，OTA 半途的 pending merge 不会被检查/取消。
# 该 inherit 同时带 ro.virtual_ab.enabled=true 与 e2fsck_ramdisk（AOSP 标准写法，
# twrp_coral / los_gs201 同款）。
$(call inherit-product, $(SRC_TARGET_DIR)/product/virtual_ab_ota.mk)

# recovery 侧属性：追加进 ramdisk 的 prop.default
TARGET_SYSTEM_PROP += $(LOCAL_PATH)/system.prop

# OTA / zip 安装时的机型断言
TARGET_OTA_ASSERT_DEVICE := bf61

# 面板 480x800；TW_THEME 显式指定，这两行只作为记录/后续自动选择用
TARGET_SCREEN_WIDTH := 480
TARGET_SCREEN_HEIGHT := 800

# ---------- TWRP ----------
# 主题选择逻辑（gui/libguitwrp_defaults.go:determineTheme）：竖屏且宽 <= 720 → portrait_mdpi。
TW_THEME := portrait_mdpi
TW_DEVICE_VERSION := bf61-1

# 亮度节点（MTK 通用 lcd-backlight）
TW_BRIGHTNESS_PATH := "/sys/class/leds/lcd-backlight/brightness"
TW_MAX_BRIGHTNESS := 255
TW_DEFAULT_BRIGHTNESS := 128

# 体积：本机 boot 分区 32 MiB，内核已占 10.9 MiB，ramdisk 必须瘦身。
# TTF 不能砍：recovery 二进制硬链接 libft2，砍掉会开机崩（TW_DISABLE_TTF 整行不写）。
TW_EXCLUDE_NANO := true
TW_EXCLUDE_BASH := true
TW_EXTRA_LANGUAGES := false

# USB：走 stock 的 configfs/musb 路线，不用 TWRP 默认的 android_usb rc
TW_EXCLUDE_DEFAULT_USB_INIT := true

# 存储 / 分区行为
TW_NO_BIND_SYSTEM := true
TW_INCLUDE_NTFS_3G := true
TW_INCLUDE_RESETPROP := true
RECOVERY_SDCARD_ON_DATA := true

# 加密：只要 TW_INCLUDE_CRYPTO=true，TWRP 的 Android.mk 会强制打开
# TW_INCLUDE_CRYPTO_FBE、-DTW_INCLUDE_FBE、-DTW_INCLUDE_FBE_METADATA_DECRYPT。
TW_INCLUDE_CRYPTO := true
TW_PREPARE_DATA_MEDIA_EARLY := true

# Android 12 的 APEX 加载在 recovery 里不是必需（各主流 12.1 树同样排除）。
# 若首启解密发现缺 apex 里的库，删掉这一行重新编译。
TW_EXCLUDE_APEX := true

# 不加载 /etc/additional.fstab：否则 /vendor 挂载后 TWRP 会拿
# /vendor/etc/fstab.<hw> 二次解析 /data、/metadata（第二趟 twrp_flags 传 NULL），
# 本树里精心对齐的 /data 加密 flag 会被 vendor 行覆盖。
TW_SKIP_ADDITIONAL_FSTAB := true

# 日志
TWRP_INCLUDE_LOGCAT := true
TARGET_USES_LOGD := true
