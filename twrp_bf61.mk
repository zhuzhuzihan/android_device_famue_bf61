#
# device/famue/bf61/twrp_bf61.mk
# 产品定义。三条 inherit 的顺序不能动：aosp_base → vendor/twrp → device.mk。
#
PRODUCT_RELEASE_NAME := bf61
DEVICE_PATH := device/famue/bf61

$(call inherit-product, $(SRC_TARGET_DIR)/product/aosp_base.mk)
$(call inherit-product, vendor/twrp/config/common.mk)
$(call inherit-product, $(DEVICE_PATH)/device.mk)

PRODUCT_DEVICE := bf61
PRODUCT_NAME := twrp_bf61
PRODUCT_BRAND := Famue
PRODUCT_MODEL := BF61
PRODUCT_MANUFACTURER := Famue
