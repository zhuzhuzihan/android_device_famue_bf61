#!/usr/bin/env bash
#
# ci/build.sh [env-file]
# TWRP twrp-12.1 + Famue BF61 设备树 → out/target/product/bf61/boot.img
#
# 本地与 GitHub Actions 共用：
#   ./ci/build.sh                 # 默认读 ci/bf61.env
#   ./ci/build.sh my.env
#
# 设计要点（对应 twrp-porting §17）：
#   · 只做 --depth=1 浅同步；JOBS = min(nproc, (RAM+swap)/4)
#   · source build/envsetup.sh 前后用 set +u 包住
#   · 构建前先跑设备树自检 tools/check-tree.sh，坏了不浪费 2 小时
#   · 构建后解析 boot.img header，确认 v2 / 2048 / cmdline / dtb 都对
#   · 失败时把 free/df/dmesg 尾巴和 build.log 尾部打进日志

set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$HERE/.." && pwd)
ENV_FILE=${1:-$HERE/bf61.env}

# shellcheck disable=SC1090
source "$ENV_FILE"

WORK=${WORK:-$SRC}
LOG_DIR=${LOG_DIR:-$REPO_ROOT/out-ci}
mkdir -p "$LOG_DIR"
BUILD_LOG=$LOG_DIR/build.log
INFO_LOG=$LOG_DIR/build-info.txt

say() { printf '\n==> %s\n' "$*"; }
warn() { printf 'WARN: %s\n' "$*"; }
die() {
    local code=$1
    shift
    printf 'ERROR: %s\n' "$*" >&2
    exit "$code"
}

diagnostics() {
    {
        printf '=== BF61 build diagnostics (%s) ===\n' "$(date -u)"
        printf -- '--- uname ---\n'; uname -a
        printf -- '--- free -h ---\n'; free -h || true
        printf -- '--- swapon ---\n'; swapon --show || true
        printf -- '--- df -h ---\n'; df -h || true
        printf -- '--- dmesg OOM/kill ---\n'
        { dmesg 2>/dev/null || sudo -n dmesg 2>/dev/null || true; } |
            grep -iE 'killed process|out of memory|oom-kill' | tail -20 || true
        printf -- '--- build.log tail ---\n'; tail -80 "$BUILD_LOG" 2>/dev/null || true
    } | tee -a "$LOG_DIR/diagnostics.txt" >&2
}

trap 'rc=$?; if [ "$rc" -ne 0 ]; then diagnostics || true; fi' EXIT

# ---------------------------------------------------------------- 资源 ----
NCPU=$(nproc)
RAM_GB=$(awk '/^MemTotal:/{printf "%d", $2/1024/1024}' /proc/meminfo)
SWAP_GB=$(awk '/^SwapTotal:/{printf "%d", $2/1024/1024}' /proc/meminfo)
EFFECTIVE_GB=$((RAM_GB + SWAP_GB))
if [ "$JOBS" = "auto" ] || [ -z "$JOBS" ]; then
    JOBS=$((EFFECTIVE_GB / 4))
    [ "$JOBS" -lt 2 ] && JOBS=2
    [ "$JOBS" -gt "$NCPU" ] && JOBS=$NCPU
fi
export JOBS NINJA_HIGHMEM_NUM_JOBS
say "RAM=${RAM_GB}GB swap=${SWAP_GB}GB vCPU=${NCPU} -> JOBS=$JOBS NINJA_HIGHMEM_NUM_JOBS=$NINJA_HIGHMEM_NUM_JOBS"

FREE_GB=$(df -BG --output=avail "$(dirname "$SRC")" 2>/dev/null | tail -1 | tr -dc '0-9')
say "磁盘可用 ${FREE_GB:-?}GB（同步约 30GB + out 约 20GB；.repo 会在同步后回收）"

# ---------------------------------------------------------------- repo ----
if ! command -v repo >/dev/null 2>&1; then
    say "安装 repo"
    mkdir -p "$HOME/.local/bin"
    curl -fsSL https://storage.googleapis.com/git-repo-downloads/repo -o "$HOME/.local/bin/repo" ||
        die 2 "下载 repo 失败"
    chmod a+x "$HOME/.local/bin/repo"
    export PATH=$HOME/.local/bin:$PATH
fi

git config --global user.name "BF61 CI"
git config --global user.email "ci@bf61.invalid"
git config --global color.ui false

mkdir -p "$SRC"
cd "$SRC"

if [ ! -d .repo ]; then
    say "repo init: $TWRP_MANIFEST ($TWRP_BRANCH)"
    repo init -u "$TWRP_MANIFEST" -b "$TWRP_BRANCH" --depth=1 --no-clone-bundle ||
        die 3 "repo init 失败"
fi

say "repo sync -c -j$JOBS"
repo sync -c -j"$JOBS" --force-sync --no-clone-bundle --no-tags ||
    die 3 "repo sync 失败（磁盘/网络；看上面第一条 error）"

# ---------------------------------------------------------------- tree ----
TREE_DST=$SRC/$DEVICE_TREE_PATH
mkdir -p "$SRC/device/famue"
if [ -n "${DEVICE_TREE_SRC:-}" ]; then
    say "从工作区复制设备树：$DEVICE_TREE_SRC -> $TREE_DST"
    # 注意 --delete：确保源树里删掉的文件不会残留在源码树里
    rsync -a --delete \
        --exclude .git --exclude research --exclude out-ci --exclude '*.log' \
        "$DEVICE_TREE_SRC/" "$TREE_DST/" || die 4 "复制设备树失败"
else
    say "浅克隆设备树：$DEVICE_TREE_URL ($DEVICE_TREE_BRANCH)"
    rm -rf "$TREE_DST"
    git clone --depth=1 -b "$DEVICE_TREE_BRANCH" "$DEVICE_TREE_URL" "$TREE_DST" ||
        die 4 "克隆设备树失败"
fi

# 同步完就不需要 .repo 的 git 元数据了：GHA 上它常占 10-15GB，
# 删掉能给 out/ 腾出空间（本地想保留 repo 状态就设 RECLAIM_DOT_REPO=0）
if [ "${RECLAIM_DOT_REPO:-1}" = "1" ] && [ -d "$SRC/.repo" ]; then
    say "回收 $SRC/.repo 以腾出构建空间"
    rm -rf "$SRC/.repo"
fi

FREE_GB=$(df -BG --output=avail "$SRC" 2>/dev/null | tail -1 | tr -dc '0-9')
MIN_FREE_GB=${MIN_FREE_GB:-18}
if [ -n "$FREE_GB" ] && [ "$FREE_GB" -lt "$MIN_FREE_GB" ]; then
    die 4 "构建前磁盘只剩 ${FREE_GB}GB（< ${MIN_FREE_GB}GB）。清 out/、减小 swap，或换自托管 runner"
fi

say "设备树自检"
(cd "$TREE_DST" && bash "$CHECK_TREE_SCRIPT" .) | tee "$LOG_DIR/tree-check.log" ||
    die 5 "tools/check-tree.sh 失败：先修设备树再编译"

{
    printf 'device_tree=%s\n' "$TREE_DST"
    printf 'device_tree_commit=%s\n' "$(git -C "$TREE_DST" rev-parse HEAD 2>/dev/null || echo '(workspace copy)')"
    printf 'kernel_sha256=%s\n' "$(sha256sum "$TREE_DST/prebuilt/kernel" | cut -d' ' -f1)"
    printf 'dtb_sha256=%s\n' "$(sha256sum "$TREE_DST"/prebuilt/dtb/*.dtb | cut -d' ' -f1)"
    printf 'dtbo_sha256=%s\n' "$(sha256sum "$TREE_DST/prebuilt/dtbo.img" | cut -d' ' -f1)"
} >"$INFO_LOG"
cat "$INFO_LOG"

# ---------------------------------------------------------------- build ----
cd "$SRC"
say "lunch $LUNCH_TARGET && mka $BUILD_TARGET"
set +u
# shellcheck disable=SC1091
. build/envsetup.sh
lunch "$LUNCH_TARGET"
set -u
# shellcheck disable=SC2086
( set -o pipefail; mka "$BUILD_TARGET" -j"$JOBS" 2>&1 | tee "$BUILD_LOG" )

# ---------------------------------------------------------------- verify ----
IMG=$SRC/out/target/product/$DEVICE/boot.img
[ -f "$IMG" ] || die 7 "构建结束但没有 $IMG"

python3 - "$IMG" "$TREE_DST/BoardConfig.mk" <<'PY' | tee "$LOG_DIR/bootimg-info.txt"
import os, re, struct, sys

img, boardconfig = sys.argv[1], sys.argv[2]
d = open(img, "rb").read()
assert d[:8] == b"ANDROID!", "不是 Android boot image"
ks, ka, rs, ra, ss, sa, ta, page, hv, osv = struct.unpack_from("<10I", d, 8)
cmdline = d[0x40:0x240].split(b"\0")[0].decode("latin-1")
extra = d[0x260:0x660].split(b"\0")[0].decode("latin-1")
hsz = struct.unpack_from("<I", d, 0x66C)[0]
dtb_size, dtb_addr = struct.unpack_from("<QQ", d, 0x670)

boot_size = 33554432
for line in open(boardconfig, encoding="utf-8", errors="replace"):
    m = re.match(r"\s*BOARD_BOOTIMAGE_PARTITION_SIZE\s*:?=\s*(\d+)", line)
    if m:
        boot_size = int(m.group(1))

print(f"image            {img}")
print(f"size             {len(d)} B / partition {boot_size} B (headroom {boot_size - len(d)} B)")
print(f"header_version   {hv}   (expect 2)")
print(f"page_size        {page}  (expect 2048)")
print(f"kernel           {ks} B @ {ka:#x}")
print(f"ramdisk          {rs} B @ {ra:#x}")
print(f"tags             {ta:#x}   dtb {dtb_size} B @ {dtb_addr:#x}")
print(f"header_size      {hsz}")
print(f"cmdline          {cmdline} {extra}".rstrip())
major = (osv >> 25) & 0x7F
minor = (osv >> 18) & 0x7F
patch = (osv >> 11) & 0x7F
year = ((osv >> 4) & 0x7F) + 2000
month = osv & 0xF
print(f"os_version       {osv:#010x}  -> {major}.{minor}.{patch} / {year:04d}-{month:02d}")

fatal = []
if hv != 2:
    fatal.append(f"header_version={hv} != 2")
if page != 2048:
    fatal.append(f"page_size={page} != 2048")
if dtb_size == 0:
    fatal.append("dtb_size=0：dtb 没有进 boot.img（检查 BOARD_INCLUDE_DTB_IN_BOOTIMG/预编译 dtb）")
if len(d) > boot_size:
    fatal.append(f"镜像 {len(d)} B 超过 boot 分区 {boot_size} B")
if "bootopt=64S3" not in cmdline:
    fatal.append("cmdline 里没有 bootopt=64S3（BOARD_KERNEL_CMDLINE 被覆盖？）")
if fatal:
    print("FATAL: " + "; ".join(fatal))
    sys.exit(1)
print("boot image header OK")
PY

# ---- ramdisk 内容断言：正常启动 lifeline（first_stage fstab）+ TWRP 关键文件 ----
RD=$(find "$SRC/out/target/product/$DEVICE" -maxdepth 1 -name 'ramdisk-recovery.img' | head -1)
[ -n "$RD" ] || die 7 "找不到 ramdisk-recovery.img（无法校验 ramdisk 内容）"

python3 - "$RD" <<'PY' | tee "$LOG_DIR/ramdisk-check.txt"
import gzip, lzma, sys

path = sys.argv[1]
magic = open(path, "rb").read(6)
if magic[:2] == b"\x1f\x8b":
    data = gzip.open(path, "rb").read()
elif magic[:3] == b"\xfd7zXZ":
    data = lzma.open(path, "rb").read()
else:
    sys.exit(f"FATAL: ramdisk-recovery.img 既不是 gzip 也不是 xz（magic={magic.hex()}），"
             f"检查 BOARD_RAMDISK_USE_LZ4 之类的压缩开关")

names, off = [], 0
while data[off:off + 6] in (b"070701", b"070702"):
    hdr = data[off:off + 110]
    size = int(hdr[54:62], 16)
    nlen = int(hdr[94:102], 16)
    name = data[off + 110:off + 110 + nlen - 1].decode("utf-8", "replace")
    off = (off + 110 + nlen + 3) & ~3        # 数据起点（4 字节对齐）
    off = (off + size + 3) & ~3              # 下一表项
    if name == "TRAILER!!!":
        break
    names.append(name)

have = set(names)
print(f"ramdisk: {path}  entries={len(names)}")
for label, key in (("init", "init"),
                   ("prop.default", "prop.default"),
                   ("twrp.flags", "system/etc/twrp.flags"),
                   ("recovery.fstab", "system/etc/recovery.fstab"),
                   ("twres/", "twres"),
                   ("first_stage fstab (normal-boot lifeline)",
                    "first_stage_ramdisk/fstab.mt6765")):
    ok = any(n == key or n.startswith(key) for n in names)
    print(f"{label:<44} {'OK' if ok else 'MISSING'}")

missing = [n for n in ("init", "prop.default", "system/etc/twrp.flags",
                       "system/etc/recovery.fstab",
                       "first_stage_ramdisk/fstab.mt6765") if n not in have]
if missing:
    print("FATAL: ramdisk missing: " + ", ".join(missing))
    sys.exit(1)
print("ramdisk content OK")
PY

say "产物校验通过"
( cd "$(dirname "$IMG")" && sha256sum boot.img > boot.img.sha256 && cat boot.img.sha256 )
say "完成：$IMG"
