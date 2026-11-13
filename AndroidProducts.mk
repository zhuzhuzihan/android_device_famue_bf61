#
# device/famue/bf61/AndroidProducts.mk
# 决定 lunch 菜单里出现什么；少了这一项 `lunch twrp_bf61-eng` 会找不到产品。
#
PRODUCT_MAKEFILES := \
    $(LOCAL_DIR)/twrp_bf61.mk

COMMON_LUNCH_CHOICES := \
    twrp_bf61-eng
