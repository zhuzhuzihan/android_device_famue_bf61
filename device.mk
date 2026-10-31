# TWRP device configuration for Famue BF61

LOCAL_PATH := device/famue/bf61

# Dynamic partitions / Virtual A/B (matches stock)
PRODUCT_USE_DYNAMIC_PARTITIONS := true
ENABLE_VIRTUAL_AB := true
$(call inherit-product, $(SRC_TARGET_DIR)/product/virtual_ab_ota.mk)

# Runtime properties
PRODUCT_PROPERTY_OVERRIDES += \
    ro.crypto.volume.filenames_mode=aes-256-cts \
    ro.boot.dynamic_partitions=true \
    ro.boot.dynamic_partitions_retrofit=false \
    ro.crypto.metadata.enabled=true
