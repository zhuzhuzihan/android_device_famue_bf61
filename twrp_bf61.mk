# TWRP product makefile for Famue BF61
# Inherit chain mirrors SebaUbuntu-style A/B recovery-as-boot trees.

$(call inherit-product, $(SRC_TARGET_DIR)/product/core_64_bit.mk)
$(call inherit-product, $(SRC_TARGET_DIR)/product/full_base_telephony.mk)

$(call inherit-product, vendor/twrp/config/common.mk)

$(call inherit-product, device/famue/bf61/device.mk)

PRODUCT_NAME := twrp_bf61
PRODUCT_DEVICE := bf61
PRODUCT_BRAND := Famue
PRODUCT_MODEL := BF61
PRODUCT_MANUFACTURER := Famue
