# TWRP device configuration for Famue BF61

DEVICE_PATH := device/famue/bf61

# Runtime properties
PRODUCT_PROPERTY_OVERRIDES += \
    ro.crypto.volume.filenames_mode=aes-256-cts \
    ro.boot.dynamic_partitions=true \
    ro.boot.dynamic_partitions_retrofit=false \
    ro.crypto.metadata.enabled=true


# Recovery install paths
TARGET_RECOVERY_FSTAB := $(DEVICE_PATH)/recovery.fstab
PRODUCT_COPY_FILES += \
    $(DEVICE_PATH)/recovery/root/init.recovery.mt6762.rc:recovery/root/init.recovery.mt6762.rc \
    $(DEVICE_PATH)/recovery/root/ueventd.mt6762.rc:recovery/root/ueventd.mt6762.rc \
    $(DEVICE_PATH)/recovery/root/etc/vintf/manifest.xml:recovery/root/etc/vintf/manifest.xml
