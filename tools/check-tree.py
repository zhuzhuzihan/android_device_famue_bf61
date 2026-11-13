#!/usr/bin/env python3
# device/famue/bf61/tools/check-tree.py
#
# 设备树静态自检：不编译、不联网，全部按 TWRP 12.1 源码语义检查。
#   python3 tools/check-tree.py [tree-root]
# 退出码：0 = 无 error；1 = 有 error。warn 不影响退出码。
#
# 检查项：
#   1. 必需文件 / 目录布局（recovery/root 不能有真实 etc 目录）
#   2. BoardConfig 变量：必需、已废弃、命名写错、分区尺寸算术
#   3. recovery.fstab：逐行判定 v1/v2、flag 合法性、分隔符、重复挂载点/块设备
#   4. twrp.flags：只允许 v1 + 分号、必须是完整行
#   5. /data 三个加密 flag + /metadata mounttodecrypt
#   6. init.recovery.*.rc：文件名、bootdevice 链接、HAL 启动触发与 service 声明
#   7. 预编译内核 / dtb / dtbo：魔数、尺寸、boot 分区余量
#   8. CI workflow 与 vendorsetup.sh 的关键点

import os
import re
import struct
import sys

ROOT = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.dirname(__file__), ".."))

errors = []
warns = []
oks = []


def ok(msg):
    oks.append(msg)


def warn(msg):
    warns.append(msg)


def err(msg):
    errors.append(msg)


def read(path):
    with open(path, "r", encoding="utf-8", errors="replace") as f:
        return f.read()


def exists(rel):
    return os.path.exists(os.path.join(ROOT, rel))


# ---------------------------------------------------------------- TWRP flag 表
# partition.cpp: tw_flags[]（android-12.1），44 项
FLAGS = {
    "andsec", "backup", "backupname=", "blocksize=", "canbewiped", "canencryptbackup",
    "defaults", "display=", "encryptable=", "fileencryption=", "metadata_encryption=",
    "flashimg", "forceencrypt=", "fsflags=", "ignoreblkid", "length=", "mounttodecrypt",
    "quota", "removable", "settingsstorage", "storage", "storagename=", "subpartitionof=",
    "symlink=", "userdataencryptbackup", "usermrf", "wipeduringfactoryreset", "wipeingui",
    "slotselect", "wait", "verify", "check", "altdevice=", "notrim", "voldmanaged=",
    "formattable", "resize", "keydirectory=", "wrappedkey", "adopted_mount_delay=",
    "dm_use_original_path", "fscompress", "logical", "metadata_csum",
}
# 只应该出现在第 5 列 / twrp.flags 的 flag（mount options 里出现即视为写错列）
TWRP_ONLY = {
    "backup", "backupname=", "canbewiped", "canencryptbackup", "display=", "flashimg",
    "ignoreblkid", "mounttodecrypt", "settingsstorage", "storage", "storagename=",
    "subpartitionof=", "userdataencryptbackup", "usermrf", "wipeduringfactoryreset",
    "wipeingui", "slotselect", "logical", "wrappedkey", "metadata_csum", "fscompress",
}
# AOSP fs_mgr flag，TWRP 不认识，只会在日志里打 Unhandled（保留会导致噪音）
AOSP_ONLY = {"first_stage_mount", "avb", "avb=", "latemount", "checkpoint=", "reservedsize=",
             "nofail", "zramsize=", "max_comp_streams=", "sysfs_path="}

KNOWN_BY_NAME = set("""
super userdata md_udc protect1 protect2 nvdata nvcfg para misc frp boot dtbo vbmeta
vbmeta_system vbmeta_vendor logo expdb seccfg nvram proinfo lk lk2 boot_para tee1 tee2
scp1 scp2 sspm_1 sspm_2 md1img md1dsp md1arm7 md3img gz1 gz2 spmfw odmdtbo preloader_a
preloader_b system system_ext vendor product
""".split())


def split_flags(value, sep):
    """按 sep 切分，双引号内的分隔符不切（Process_TW_Flags 的行为）。"""
    out, cur, quoted = [], [], False
    for ch in value:
        if ch == '"':
            quoted = not quoted
        if ch == sep and not quoted:
            out.append("".join(cur))
            cur = []
            continue
        cur.append(ch)
    out.append("".join(cur))
    return [x.strip() for x in out if x.strip()]


def flag_name(token):
    for f in FLAGS:
        if f.endswith("="):
            if token.startswith(f):
                return f
        elif token == f or token.startswith(f + "="):
            return f
    return None


def check_flags(where, tokens, lineno, strict_semicolon=False):
    for t in tokens:
        name = flag_name(t)
        if name is None:
            err(f"{where}:{lineno}: 未识别的 TWRP flag '{t}'（源码只会打 Unhandled flag，不会报错）")
            continue
        if strict_semicolon and "," in t:
            err(f"{where}:{lineno}: flag '{t}' 含逗号 —— twrp.flags 必须用 ';' 分隔")


# ---------------------------------------------------------------- 1. 布局
def check_layout():
    required = [
        "AndroidProducts.mk", "BoardConfig.mk", "device.mk", "twrp_bf61.mk",
        "vendorsetup.sh", "system.prop",
        "prebuilt/kernel", "prebuilt/dtbo.img",
        "recovery/root/system/etc/recovery.fstab",
        "recovery/root/system/etc/twrp.flags",
    ]
    for rel in required:
        if exists(rel):
            ok(f"存在 {rel}")
        else:
            err(f"缺少 {rel}")

    if os.path.isdir(os.path.join(ROOT, "recovery/root/etc")):
        err("recovery/root/etc 是真实目录：会覆盖 ramdisk 里 /etc -> /system/etc 的软链接")
    else:
        ok("recovery/root 下没有真实 etc 目录")

    dtbs = [f for f in os.listdir(os.path.join(ROOT, "prebuilt/dtb")) if f.endswith(".dtb")] \
        if os.path.isdir(os.path.join(ROOT, "prebuilt/dtb")) else []
    if len(dtbs) == 1:
        ok(f"prebuilt/dtb 只有 1 个 dtb：{dtbs[0]}")
    elif not dtbs:
        err("prebuilt/dtb 下没有 *.dtb（BOARD_PREBUILT_DTBIMAGE_DIR 会 cat 空目录）")
    else:
        warn(f"prebuilt/dtb 有多个 dtb，会按字典序全部拼进 boot.img：{dtbs}")

    for dirpath, dirnames, filenames in os.walk(ROOT):
        if ".git" in dirpath or "research" in dirpath or "prebuilt" in dirpath:
            continue
        for fn in filenames:
            p = os.path.join(dirpath, fn)
            if fn.endswith((".png", ".gz", ".img", ".dtb", ".pyc")):
                continue
            try:
                data = open(p, "rb").read()
            except OSError:
                continue
            if b"\0" in data:      # 二进制文件不查换行
                continue
            if b"\r\n" in data:
                err(f"{os.path.relpath(p, ROOT)} 使用了 CRLF 换行（make/init 解析会出问题）")


# ---------------------------------------------------------------- 2. BoardConfig
def parse_make(path):
    defines = {}
    for line in read(path).splitlines():
        s = line.split("#", 1)[0].strip()
        m = re.match(r"^(?:export\s+)?([A-Z0-9_]+)\s*(\?=|:=|\+=|=)\s*(.*)$", s)
        if m:
            key, op, val = m.group(1), m.group(2), m.group(3).strip()
            defines[key] = (op, val)
    return defines


def get(defs, key, default=""):
    return defs.get(key, ("", default))[1]


def resolve(val, defs, depth=0):
    if depth > 5:
        return val
    m = re.fullmatch(r"\$\(([A-Z0-9_]+)\)", val.strip())
    if m:
        return resolve(get(defs, m.group(1)), defs, depth + 1)
    return val


def check_boardconfig():
    bc_path = os.path.join(ROOT, "BoardConfig.mk")
    dev_path = os.path.join(ROOT, "device.mk")
    if not (os.path.exists(bc_path) and os.path.exists(dev_path)):
        return
    bc = parse_make(bc_path)
    dev = parse_make(dev_path)
    both = {**bc, **dev}

    def want_true(key, where="BoardConfig.mk"):
        v = get(both, key)
        if v.lower() != "true":
            err(f"{where}: {key} 必须为 true（当前 '{v or '<未设置>'}'）")
        else:
            ok(f"{key} := true")

    want_true("ALLOW_MISSING_DEPENDENCIES")
    want_true("BOARD_USES_RECOVERY_AS_BOOT")
    want_true("AB_OTA_UPDATER")
    want_true("TW_INCLUDE_CRYPTO")
    want_true("PRODUCT_USE_DYNAMIC_PARTITIONS")
    want_true("TW_SKIP_ADDITIONAL_FSTAB")

    hv = get(both, "BOARD_BOOT_HEADER_VERSION")
    if hv != "2":
        err(f"BOARD_BOOT_HEADER_VERSION 应为 2（当前 '{hv or '<未设置>'}'）")
    else:
        ok("BOARD_BOOT_HEADER_VERSION := 2")

    if "BOARD_BOOTIMG_HEADER_VERSION" in both:
        err("BOARD_BOOTIMG_HEADER_VERSION 是死变量（12.1 无消费者），改名 BOARD_BOOT_HEADER_VERSION")

    args = get(both, "BOARD_MKBOOTIMG_ARGS") + " " + " ".join(
        v for k, (op, v) in both.items() if k == "BOARD_MKBOOTIMG_ARGS")
    for token in ("--header_version", "--base", "--pagesize", "--ramdisk_offset",
                  "--tags_offset", "--dtb_offset", "--kernel_offset"):
        if token not in read(bc_path):
            err(f"BoardConfig.mk 的 BOARD_MKBOOTIMG_ARGS 缺少 {token}（12.1 不会自动补）")
    if "--header_version" in read(bc_path):
        ok("BOARD_MKBOOTIMG_ARGS 显式传了 header/offset 参数")

    want_true("BOARD_INCLUDE_DTB_IN_BOOTIMG")
    if not get(both, "BOARD_PREBUILT_DTBIMAGE_DIR"):
        err("BOARD_INCLUDE_DTB_IN_BOOTIMG 需要配对 BOARD_PREBUILT_DTBIMAGE_DIR")
    if not get(both, "TARGET_PREBUILT_KERNEL"):
        err("缺 TARGET_PREBUILT_KERNEL")

    if "LOCAL_KERNEL" not in read(dev_path) or "PRODUCT_COPY_FILES" not in read(dev_path):
        err("device.mk 未把内核拷到 $(PRODUCT_OUT)/kernel（LOCAL_KERNEL + PRODUCT_COPY_FILES）")
    elif re.search(r"PRODUCT_COPY_FILES\s*\+?=.*:kernel", read(dev_path)):
        ok("device.mk 把 prebuilt/kernel 拷成 $(PRODUCT_OUT)/kernel")
    else:
        err("device.mk 的 PRODUCT_COPY_FILES 目标不是 :kernel")

    for dead in ("TW_HAS_NO_RECOVERY_PARTITION", "TW_EXCLUDE_TWRPAPP",
                 "TW_SCREEN_BLANK_ON_BOOT", "TARGET_PREBUILT_DTB",
                 "BOARD_MOVE_RECOVERY_RESOURCES_TO_VENDOR_BOOT",
                 "BOARD_RECOVERYIMAGE_PARTITION_SIZE", "ENABLE_VIRTUAL_AB"):
        if dead in both:
            warn(f"{dead} 在 12.1 里没有消费者/不适用（当前仓库仍写着）")

    fstab = resolve(get(both, "TARGET_RECOVERY_FSTAB"), both)
    device_path = get(both, "DEVICE_PATH", "device/famue/bf61")
    fstab = fstab.replace("$(DEVICE_PATH)", device_path).replace("$(LOCAL_PATH)", device_path)
    # TARGET_RECOVERY_FSTAB 是相对源码根的路径；本自检把仓库本身当树根
    repo_rel = fstab[len(device_path) + 1:] if fstab.startswith(device_path + "/") else fstab
    if fstab and not os.path.exists(os.path.join(ROOT, repo_rel)):
        err(f"TARGET_RECOVERY_FSTAB 指向的 {fstab} 不存在（相对源码根）")
    elif fstab:
        ok(f"TARGET_RECOVERY_FSTAB -> {fstab}")

    try:
        super_size = int(get(both, "BOARD_SUPER_PARTITION_SIZE") or 0)
        main_size = int(get(both, "BOARD_MAIN_SIZE") or 0)
        if super_size and main_size and main_size >= super_size:
            err("BOARD_MAIN_SIZE 必须小于 BOARD_SUPER_PARTITION_SIZE（要留 LP metadata）")
        elif super_size and main_size:
            ok(f"super 尺寸算术正常（差 {super_size - main_size} B 给 metadata）")
    except ValueError:
        err("BOARD_SUPER_PARTITION_SIZE / BOARD_MAIN_SIZE 不是十进制整数")

    if get(both, "BOARD_PREBUILT_DTBOIMAGE"):
        ok("BOARD_PREBUILT_DTBOIMAGE 已设置")


# ---------------------------------------------------------------- 3/4/5. fstab
def parse_fstab_line(line):
    """返回 (version, src, mnt, fstype, opts, flags) 或 None；version: 1/2。"""
    s = line.strip()
    if not s or s.startswith("#"):
        return None
    parts = re.findall(r'(?:[^\s"]|"[^"]*")+', s)
    if len(parts) < 3:
        return None
    if parts[0].startswith(("/dev/", "/devices/")):
        version = 2
        src, mnt, fstype = parts[0], parts[1], parts[2]
        opts = parts[3] if len(parts) > 3 else ""
        flags = parts[4] if len(parts) > 4 else ""
    elif not parts[0].startswith("/"):
        version = 2
        src, mnt, fstype = parts[0], parts[1], parts[2]
        opts = parts[3] if len(parts) > 3 else ""
        flags = parts[4] if len(parts) > 4 else ""
    else:
        version = 1
        mnt, fstype, src = parts[0], parts[1], parts[2]
        flags = ""
        for p in parts[3:]:
            if p.startswith("flags="):
                flags = p[len("flags="):]
        opts = ""
    return version, src, mnt, fstype, opts, flags


def check_fstabs():
    rel = "recovery/root/system/etc/recovery.fstab"
    if not exists(rel):
        return
    lines = read(os.path.join(ROOT, rel)).splitlines()
    mounts, devices = {}, {}
    data_flags = set()
    metadata_mounttodecrypt = False
    logical = {}

    for i, line in enumerate(lines, 1):
        p = parse_fstab_line(line)
        if not p:
            continue
        version, src, mnt, fstype, opts, flags = p
        if mnt in mounts and mnt != "auto":
            err(f"{rel}:{i}: 挂载点 {mnt} 重复（TWRP 会建两个同名分区）")
        elif mnt == "auto":
            # /devices/... 行的 mount point 写 auto，TWRP 会依次改成 /auto0、/auto1
            mnt = f"auto#{i}"
        mounts[mnt] = (version, src, fstype)
        if src.startswith("/dev/") and src in devices:
            err(f"{rel}:{i}: 块设备 {src} 被 {devices[src]} 和 {mnt} 重复占用")
        devices[src] = mnt

        if version == 2:
            for t in split_flags(opts, ","):
                name = flag_name(t)
                if name in TWRP_ONLY:
                    err(f"{rel}:{i}: '{t}' 写在 mount options 列（第 4 列），TWRP 只解析第 5 列")
            toks = split_flags(flags, ",")
            for t in toks:
                if t.startswith(("avb=", "first_stage_mount", "latemount", "checkpoint=",
                                 "reservedsize=")):
                    warn(f"{rel}:{i}: '{t}' 是 AOSP fs_mgr flag，TWRP 不认（日志噪音）")
            check_flags(rel, toks, i)
            if "logical" in [flag_name(t) for t in toks]:
                logical[mnt] = src
            if mnt == "/data":
                data_flags = {flag_name(t) for t in toks}
            if mnt == "/metadata" and "mounttodecrypt" in [flag_name(t) for t in toks]:
                metadata_mounttodecrypt = True
        else:
            err(f"{rel}:{i}: 这是 v1 行（挂载点开头），主表里请用 AOSP v2 顺序，"
                f"或者把私有 flag 移到 twrp.flags")

        mname = mnt.rstrip("/").split("/")[-1]
        if src.startswith("/dev/block/by-name/"):
            part = src.rsplit("/", 1)[-1]
            if part not in KNOWN_BY_NAME:
                warn(f"{rel}:{i}: by-name 分区 '{part}' 不在 stock fstab 清单里，确认拼写")

    if "/data" not in mounts:
        err(f"{rel}: 没有 /data 条目")
    for need in ("fileencryption=", "metadata_encryption=", "keydirectory="):
        if need not in data_flags:
            err(f"{rel}: /data 缺 {need}（FBE v2 + metadata 解密三件套）")

    order = [m for m in mounts]
    if "/metadata" in mounts and "/data" in mounts:
        if order.index("/metadata") > order.index("/data"):
            warn(f"{rel}: /metadata 建议排在 /data 前面（解密前先挂 metadata）")
    if "/super" in mounts or "/super" in [m for m in mounts]:
        err(f"{rel}: 不要手写 /super，TWRP 的 Setup_Super_Partition() 会自己加（无去重）")

    for mnt, src in logical.items():
        if src.startswith("/dev/"):
            warn(f"{rel}: 逻辑分区 {mnt} 的源列是设备路径；写裸逻辑名更直观（两者都能工作）")

    ok(f"recovery.fstab：{len(mounts)} 个挂载点，v2 解析与 flag 校验完成")

    # ---------------- twrp.flags
    rel2 = "recovery/root/system/etc/twrp.flags"
    if not exists(rel2):
        return
    lines2 = read(os.path.join(ROOT, rel2)).splitlines()
    seen = set()
    for i, line in enumerate(lines2, 1):
        s = line.strip()
        if not s or s.startswith("#"):
            continue
        parts = re.findall(r'(?:[^\s"]|"[^"]*")+', s)
        if not parts[0].startswith("/"):
            err(f"{rel2}:{i}: 必须以挂载点开头（v1 格式），否则会被判成 v2 用逗号切分")
            continue
        if len(parts) < 3:
            err(f"{rel2}:{i}: 行不完整，至少需要 <挂载点> <fs> <设备>")
            continue
        mnt = parts[0]
        if mnt in seen:
            err(f"{rel2}:{i}: 挂载点 {mnt} 重复")
        seen.add(mnt)
        flags_token = next((p for p in parts[3:] if p.startswith("flags=")), None)
        if flags_token is None:
            err(f"{rel2}:{i}: 没有 flags=（这行不会产生任何 TWRP 行为）")
            continue
        raw = flags_token[len("flags="):]
        if "," in raw and ";" not in raw:
            err(f"{rel2}:{i}: 用了逗号分隔 —— 源码强制按 v1 解析，会整行吞掉")
        check_flags(rel2, split_flags(raw, ";"), i, strict_semicolon=True)
        dev = parts[2]
        if dev.startswith("/dev/block/by-name/"):
            part = dev.rsplit("/", 1)[-1]
            if part not in KNOWN_BY_NAME:
                warn(f"{rel2}:{i}: by-name 分区 '{part}' 不在 stock fstab 清单里")
        if mnt == "/system":
            err(f"{rel2}:{i}: 不要给 /system 打补丁 —— TWRP 会把它改名 /system_root，"
                f"查不到原挂载点还会重复追加分区")
        if mnt in mounts:
            mver = mounts[mnt][0]
            if mver == 1:
                warn(f"{rel2}:{i}: 主表同挂载点是 v1，twrp.flags 不会覆盖它（只追加新挂载点）")
    # mounttodecrypt 允许写在 twrp.flags（推荐），也可以在 fstab；两者合并判断
    meta_tokens = ""
    for line in lines2:
        if line.strip().startswith("/metadata"):
            meta_tokens = line
    if "mounttodecrypt" not in meta_tokens:
        err(f"{rel2}: /metadata 没有 mounttodecrypt（解密前不会挂载密钥分区）")
    ok(f"twrp.flags：{len(seen)} 行，全部 v1 + 分号分隔")


# ---------------------------------------------------------------- 6. init rc
def check_initrc():
    files = [f for f in os.listdir(os.path.join(ROOT, "recovery/root"))
             if f.startswith("init.recovery.") and f.endswith(".rc")] \
        if os.path.isdir(os.path.join(ROOT, "recovery/root")) else []
    if not files:
        err("recovery/root 下没有 init.recovery.<ro.hardware>.rc")
        return
    if "init.recovery.mt6765.rc" not in files:
        err(f"init rc 文件名与 ro.hardware 不匹配：{files}（本机 DTB: androidboot.hardware=mt6765）")
    for fn in files:
        text = read(os.path.join(ROOT, "recovery/root", fn))
        if re.fullmatch(r"\s*#.*?\n\s*import\s+\S+\s*", text, re.S):
            ok(f"{fn}: 纯 import 转发文件，跳过内容检查")
            continue
        for need in ("symlink /dev/block/platform/bootdevice /dev/block/bootdevice",
                     "setprop sys.usb.controller", "twrp.mount_to_decrypt"):
            if need.split()[0] not in text or need.split()[-1] not in text:
                warn(f"{fn}: 没有找到 '{need}'（检查是否漏了）")
        services = set(re.findall(r"^service\s+(\S+)", text, re.M))
        start = set(re.findall(r"^\s+start\s+(\S+)", text, re.M))
        unknown = start - services
        if unknown:
            err(f"{fn}: start 了未声明的 service：{sorted(unknown)}")
        if services and not start:
            warn(f"{fn}: 声明了 service 但没有 start 触发（disabled 的服务永远不会跑）")
        if services:
            ok(f"{fn}: service {sorted(services)} 均有 start 触发")
        # 服务二进制路径必须在 /vendor 挂载后才可执行
        for m in re.finditer(r"^service\s+\S+\s+(/vendor/\S+|\S+)", text, re.M):
            path = m.group(1)
            if path.startswith("/vendor/") and "twrp.mount_to_decrypt" not in text:
                err(f"{fn}: {path} 在 /vendor 里，必须等 vendor 挂载后再 start")


# ---------------------------------------------------------------- 7. 预编译件
def check_prebuilts():
    kernel = os.path.join(ROOT, "prebuilt/kernel")
    dtbdir = os.path.join(ROOT, "prebuilt/dtb")
    dtbo = os.path.join(ROOT, "prebuilt/dtbo.img")
    if os.path.exists(kernel):
        data = open(kernel, "rb").read(4)
        size = os.path.getsize(kernel)
        if data[:2] == b"\x1f\x8b":
            ok(f"kernel 是 gzip Image.gz（{size} B）")
        else:
            warn(f"kernel 魔数 {data.hex()} 不是 gzip，确认 BOARD_KERNEL_IMAGE_NAME")
        boot_size = 33554432
        bc = parse_make(os.path.join(ROOT, "BoardConfig.mk"))
        try:
            boot_size = int(get(bc, "BOARD_BOOTIMAGE_PARTITION_SIZE") or boot_size)
        except ValueError:
            pass
        if size > boot_size:
            err(f"kernel {size} B 已超过 boot 分区 {boot_size} B")
        else:
            ok(f"boot 分区给 ramdisk 留了 {boot_size - size} B（kernel + dtb 之外）")
    for f in (os.listdir(dtbdir) if os.path.isdir(dtbdir) else []):
        if not f.endswith(".dtb"):
            continue
        d = open(os.path.join(dtbdir, f), "rb").read()
        if d[:4] == b"\xd7\xb7\xab\x1e":
            total = struct.unpack_from(">I", d, 4)[0]
            if total != len(d):
                err(f"prebuilt/dtb/{f}: dt_table total_size={total} 与文件长度 {len(d)} 不一致")
            else:
                ok(f"dtb 容器 {f} 自洽（dt_table total_size={total}）")
        elif d[:4] == b"\xd0\x0d\xfe\xed":
            warn(f"prebuilt/dtb/{f} 是裸 FDT；stock 的 boot dtb 段是 dt_table 容器，确认没有丢表头")
        else:
            err(f"prebuilt/dtb/{f}: 既不是 dt_table 也不是 FDT")
    if os.path.exists(dtbo):
        d = open(dtbo, "rb").read()
        if d[:4] == b"\xd7\xb7\xab\x1e":
            total = struct.unpack_from(">I", d, 4)[0]
            if total != len(d):
                err(f"prebuilt/dtbo.img: total_size={total} != 文件长度 {len(d)}（多出来的填充会浪费/报错）")
            else:
                ok(f"dtbo.img 已裁到真实长度 {total} B（不是 8 MiB 整分区转储）")
        else:
            err("prebuilt/dtbo.img 不是 dt_table 格式")


# ---------------------------------------------------------------- 8. CI / 杂项
def check_ci():
    wf = os.path.join(ROOT, ".github/workflows/build.yml")
    env = os.path.join(ROOT, "ci/bf61.env")
    script = os.path.join(ROOT, "ci/build.sh")
    if not os.path.exists(wf):
        warn("没有 .github/workflows/build.yml")
        return
    wf_text = read(wf)
    env_text = read(env) if os.path.exists(env) else ""
    sh_text = read(script) if os.path.exists(script) else ""

    if "bootimage" not in (wf_text + env_text + sh_text):
        err("CI 未构建 bootimage（本机 recovery-as-boot，产物是 boot.img）")
    elif "mka recoveryimage" in wf_text or "BUILD_TARGET=recoveryimage" in env_text:
        err("CI 在构建 recoveryimage，本机没有 recovery 分区")
    else:
        ok("CI 构建目标是 bootimage")

    if "DEVICE_TREE_SRC" not in wf_text or "github.workspace" not in wf_text:
        warn("CI 没有把工作区（被推送的 commit）传给构建脚本，可能编的是默认分支")
    else:
        ok("CI 用 ${{ github.workspace }} 构建当前 commit")

    if "envsetup.sh" in sh_text and "set +u" not in sh_text:
        warn("ci/build.sh source build/envsetup.sh 前没有 set +u 保护")
    elif "set +u" in sh_text:
        ok("ci/build.sh 用 set +u 包住了 envsetup.sh")

    if "NINJA_HIGHMEM_NUM_JOBS" not in (wf_text + sh_text + env_text):
        warn("没有设 NINJA_HIGHMEM_NUM_JOBS（4 核 + 16G 上容易 OOM）")
    else:
        ok("NINJA_HIGHMEM_NUM_JOBS 已设置")

    if "swap-storage: false" not in wf_text and "swapoff" not in wf_text:
        warn("CI 没有处理 swap（Windows/GHA 上不要用 free-disk-space 的 swap-storage=true）")
    else:
        ok("CI swap 处理符合指南（swap-storage=false / 自建 swap）")

    vs = os.path.join(ROOT, "vendorsetup.sh")
    if os.path.exists(vs) and "ALLOW_MISSING_DEPENDENCIES" not in read(vs):
        err("vendorsetup.sh 没有 export ALLOW_MISSING_DEPENDENCIES=true")
    elif os.path.exists(vs):
        ok("vendorsetup.sh 设置了 ALLOW_MISSING_DEPENDENCIES")


def main():
    print(f"== device tree self-check: {ROOT}")
    check_layout()
    check_boardconfig()
    check_fstabs()
    check_initrc()
    check_prebuilts()
    check_ci()

    for m in oks:
        print(f"  ok    {m}")
    for m in warns:
        print(f"  WARN  {m}")
    for m in errors:
        print(f"  ERROR {m}")
    print(f"\n== {len(oks)} ok, {len(warns)} warn, {len(errors)} error")
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
