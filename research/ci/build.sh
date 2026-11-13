#!/usr/bin/env bash
# =============================================================================
# BF61 (Famue BF61, MT6762 / MT6765 BSP) — TWRP twrp-12.1 build driver
#
# Shared by GitHub Actions (.github/workflows/build.yml) and local runs.
# Implements references/17-github-actions.md: repo init/sync flags, staged
# tree materialisation at an exact commit, ALLOW_MISSING_DEPENDENCIES,
# set +u around envsetup.sh, JOBS = min(nproc, (RAM+swap)/4),
# NINJA_HIGHMEM_NUM_JOBS=2, OOM/ENOSPC diagnostics, boot.img verification,
# artifact packaging with SHA256SUMS.
#
#   ci/build.sh <env-file> [stage[,stage...]]
#
#   stages (default = all):
#     preflight  memory / swap / disk budget / tool checks; fail fast
#     sync       repo init (--depth=1) + repo sync (-c --optimized-fetch ...)
#     tree       materialise $DEVICE_TREE_SRC@$DEVICE_TREE_REV into
#                $SRC/device/<vendor>/<device>, verify the commit,
#                run `bash tools/check-tree.sh`
#     ccache     configure ccache (optional, size-capped)
#     build      lunch + mka $BUILD_TARGET  (piped to build.log)
#     verify     boot.img header v2 + ramdisk payload verification
#     package    artifacts/ + SHA256SUMS
#
# Exit codes: 0 ok | 2 usage | 3 preflight budget | 4 sync | 5 tree/check-tree
#             6 build | 7 verify | 8 package
#
# The script is deliberately dependency-light: bash, coreutils, awk, git,
# python3, rsync, curl. No third-party actions or binaries are required.
# =============================================================================
set -euo pipefail

PROG=${0##*/}
DRIVER_LOG=""

# ------------------------------------------------------------------ usage ---
usage() {
    printf 'Usage: %s <env-file> [stage[,stage...]]\n\n' "$PROG"
    sed -n '2,30p' "$0" | sed -e 's/^# \{0,1\}//'
    cat <<'EOF'

Examples:
  # full local build (fetches the device tree from GitHub)
  DEVICE_TREE_REV=$(git rev-parse HEAD) ./ci/build.sh devices/bf61.env all
  # CI: same thing but the tree comes from the already-checked-out workspace
  DEVICE_TREE_SRC=$PWD DEVICE_TREE_REV=$GITHUB_SHA ./ci/build.sh devices/bf61.env sync,tree,build
  # only re-verify an existing image
  ./ci/build.sh devices/bf61.env verify
EOF
}

die() {
    local rc=$1; shift
    if [ -n "$DRIVER_LOG" ]; then printf 'FATAL: %s\n' "$*" >>"$DRIVER_LOG" 2>/dev/null || true; fi
    printf 'FATAL: %s\n' "$*" >&2
    if [ "${GITHUB_ACTIONS:-}" = "true" ]; then printf '::error::%s\n' "$*"; fi
    exit "$rc"
}

say() {
    local msg
    msg=$(printf '[%s] %s' "$(date -u +%H:%M:%SZ)" "$*")
    printf '%s\n' "$msg"
    if [ -n "$DRIVER_LOG" ]; then printf '%s\n' "$msg" >>"$DRIVER_LOG" 2>/dev/null || true; fi
}

warn() {
    say "WARN: $*"
    if [ "${GITHUB_ACTIONS:-}" = "true" ]; then printf '::warning::%s\n' "$*"; fi
}

group() {
    if [ "${GITHUB_ACTIONS:-}" = "true" ]; then printf '::group::%s\n' "$*"; fi
    say "=== $* ==="
}

endgroup() {
    if [ "${GITHUB_ACTIONS:-}" = "true" ]; then printf '::endgroup::\n'; fi
}

is_uint() { case "${1:-}" in '' | *[!0-9]*) return 1 ;; *) return 0 ;; esac; }

# ------------------------------------------------------------- arguments ---
case "${1:-}" in
    -h | --help | help) usage; exit 0 ;;
esac
[ $# -ge 1 ] || { usage; exit 2; }
ENV_FILE=$1
STAGES_RAW=${2:-all}

[ -f "$ENV_FILE" ] || die 2 "env 文件不存在: $ENV_FILE"
# shellcheck disable=SC1090
. "$ENV_FILE"

for v in DEVICE VENDOR DEVICE_TREE_PATH TWRP_MANIFEST TWRP_BRANCH LUNCH_TARGET BUILD_TARGET; do
    [ -n "${!v:-}" ] || die 2 "$ENV_FILE 缺少必填变量 $v"
done

# ------------------------------------------------------------------ paths ---
WORK=${WORK:-$PWD/work}
SRC=${SRC:-$WORK/src}
LOG_DIR=${LOG_DIR:-$WORK/logs}
ART=${ART:-$WORK/artifacts}
CCACHE_DIR=${CCACHE_DIR:-$WORK/.ccache}
mkdir -p "$WORK" "$LOG_DIR" "$ART"
DRIVER_LOG="$LOG_DIR/driver.log"
: >"$DRIVER_LOG"

# ------------------------------------------------------------- resources ---
JOBS=${JOBS:-auto}
NINJA_HIGHMEM_NUM_JOBS=${NINJA_HIGHMEM_NUM_JOBS:-2}
SWAP_GB=${SWAP_GB:-8}
CCACHE_ENABLE=${CCACHE_ENABLE:-1}
CCACHE_SIZE=${CCACHE_SIZE:-5G}
RECLAIM_DOT_REPO=${RECLAIM_DOT_REPO:-1}
MIN_FREE_GB_BEFORE_SYNC=${MIN_FREE_GB_BEFORE_SYNC:-40}
MIN_FREE_GB_AFTER_SYNC=${MIN_FREE_GB_AFTER_SYNC:-14}
MIN_FREE_GB_BEFORE_BUILD=${MIN_FREE_GB_BEFORE_BUILD:-12}
CHECK_TREE_SCRIPT=${CHECK_TREE_SCRIPT:-tools/check-tree.sh}
SKIP_CHECK_TREE=${SKIP_CHECK_TREE:-0}
BOOT_PARTITION_SIZE=${BOOT_PARTITION_SIZE:-33554432}
BOOT_HEADER_VERSION=${BOOT_HEADER_VERSION:-2}
BOOT_PAGE_SIZE=${BOOT_PAGE_SIZE:-2048}
BOOT_SIZE_WARN_RATIO=${BOOT_SIZE_WARN_RATIO:-0.94}
BOOT_CMDLINE_EXPECT=${BOOT_CMDLINE_EXPECT:-}
EXPECT_KERNEL_MAGIC=${EXPECT_KERNEL_MAGIC:-gzip}
PREBUILT_KERNEL=${PREBUILT_KERNEL:-prebuilt/kernel}
PREBUILT_DTB=${PREBUILT_DTB:-prebuilt/dtb.img}
PREBUILT_DTBO=${PREBUILT_DTBO:-prebuilt/dtbo.img}
DEVICE_TREE_URL=${DEVICE_TREE_URL:-}
DEVICE_TREE_SRC=${DEVICE_TREE_SRC:-}
DEVICE_TREE_REV=${DEVICE_TREE_REV:-}
DEVICE_TREE_BRANCH=${DEVICE_TREE_BRANCH:-main}
STRICT_RAMDISK=${STRICT_RAMDISK:-1}
PACKAGE_STRICT=${PACKAGE_STRICT:-0}

NCPU=$(nproc 2>/dev/null || echo 4)

mem_kb() { awk -v key="$1" '$1==key":"{printf "%d", ($2/1048576)+0.5}' /proc/meminfo 2>/dev/null || echo 0; }
RAM_GB=$(mem_kb MemTotal); RAM_GB=${RAM_GB:-16}; is_uint "$RAM_GB" || RAM_GB=16
SWAP_NOW_GB=$(mem_kb SwapTotal); SWAP_NOW_GB=${SWAP_NOW_GB:-0}; is_uint "$SWAP_NOW_GB" || SWAP_NOW_GB=0
EFFECTIVE_GB=$((RAM_GB + SWAP_NOW_GB))

if [ "$JOBS" = "auto" ] || [ -z "$JOBS" ]; then
    JOBS=$((EFFECTIVE_GB / 4))
    if [ "$JOBS" -lt 2 ]; then JOBS=2; fi
    if [ "$JOBS" -gt "$NCPU" ]; then JOBS=$NCPU; fi
fi
is_uint "$JOBS" || die 2 "JOBS 必须是整数或 auto (当前: $JOBS)"
is_uint "$NINJA_HIGHMEM_NUM_JOBS" || die 2 "NINJA_HIGHMEM_NUM_JOBS 必须是整数"
export JOBS NINJA_HIGHMEM_NUM_JOBS

free_gb() {
    df -Pk "${1:-$WORK}" 2>/dev/null | awk 'NR==2{printf "%d", ($4/1048576)+0.5}'
}
du_mb() {
    local v
    v=$(du -sm "${1:-.}" 2>/dev/null | awk '{print $1}')
    printf '%s' "${v:-0}"
}

# ----------------------------------------------------------- ccache setup ---
setup_ccache_env() {
    if [ "$CCACHE_ENABLE" != "1" ]; then return 0; fi
    command -v ccache >/dev/null 2>&1 || return 0
    export USE_CCACHE=1
    export CCACHE_DIR
    CCACHE_EXEC=$(command -v ccache)
    export CCACHE_EXEC
}

# =================================================================== stages ==
stage_preflight() {
    group "preflight: 内存 / swap / 磁盘 / 工具链"
    say "RAM=${RAM_GB}GB  swap=${SWAP_NOW_GB}GB  effective=${EFFECTIVE_GB}GB  vCPU=${NCPU}"
    say "JOBS=${JOBS}  NINJA_HIGHMEM_NUM_JOBS=${NINJA_HIGHMEM_NUM_JOBS}  (= min(nproc, (RAM+swap)/4))"
    say "WORK=$WORK  SRC=$SRC  CCACHE_DIR=$CCACHE_DIR"
    if [ "$SWAP_NOW_GB" -lt 2 ]; then
        warn "swap 只有 ${SWAP_NOW_GB}GB。16GB RAM 上 soong 峰值可到 ~20GB，没有 swap 时 JOBS=4 也可能被 OOM killer 杀掉。"
    fi
    local missing="" t
    for t in awk git python3 sed grep find od stat tee sha256sum df du tr xargs; do
        if ! command -v "$t" >/dev/null 2>&1; then missing="$missing $t"; fi
    done
    if [ -n "$missing" ]; then
        die 3 "缺少必需工具:$missing  (apt-get install -y python3 git coreutils findutils)"
    fi
    for t in curl rsync ccache lz4 unzip; do
        if ! command -v "$t" >/dev/null 2>&1; then
            say "可选工具缺失: $t（$(case $t in
                curl) echo '只在需要下载 repo 时才用' ;;
                rsync) echo '缺失时 tree 阶段退回 cp -a' ;;
                ccache) echo '缺失时跳过 ccache' ;;
                lz4) echo '缺失时无法校验 lz4 ramdisk，gzip 不受影响' ;;
                *) echo '不影响 bootimage 构建' ;;
            esac)）"
        fi
    done
    local free_now
    free_now=$(free_gb "$WORK"); free_now=${free_now:-0}
    say "磁盘可用: ${free_now}GB ($WORK)"
    if [ "$free_now" -lt "$MIN_FREE_GB_BEFORE_SYNC" ]; then
        if [ "${ALLOW_TIGHT_DISK:-0}" = "1" ]; then
            warn "ALLOW_TIGHT_DISK=1: 可用 ${free_now}GB < ${MIN_FREE_GB_BEFORE_SYNC}GB，继续但很可能在 sync/link 阶段 ENOSPC"
        else
            say "预算参考: twrp-12.1 源码 ~30GB(.repo 对象另计) + bootimage 的 out/ ~15-25GB"
            say "释放磁盘: 删 /usr/local/lib/android /usr/share/dotnet /opt/ghc /usr/local/.ghcup /opt/hostedtoolcache,"
            say "          sudo docker image prune -af —— 且绝不要动 swap（free-disk-space 的 swap-storage 必须为 false）"
            die 3 "磁盘预算不足: 可用 ${free_now}GB < 要求 ${MIN_FREE_GB_BEFORE_SYNC}GB（要跳过: ALLOW_TIGHT_DISK=1）"
        fi
    fi
    endgroup
}

ensure_repo() {
    if command -v repo >/dev/null 2>&1; then
        say "repo: $(command -v repo)"
        return 0
    fi
    mkdir -p "$WORK/bin"
    say "下载 repo 工具 -> $WORK/bin/repo"
    curl -fsSL https://storage.googleapis.com/git-repo-downloads/repo -o "$WORK/bin/repo" ||
        die 4 "下载 repo 失败（网络受限？可预置 repo 到 PATH）"
    chmod +x "$WORK/bin/repo"
    export PATH="$WORK/bin:$PATH"
    if [ -n "${GITHUB_PATH:-}" ]; then printf '%s\n' "$WORK/bin" >>"$GITHUB_PATH"; fi
}

git_identity() {
    if [ -z "$(git config --global user.email 2>/dev/null || true)" ]; then
        git config --global user.name "BF61 CI"
        git config --global user.email "ci@example.invalid"
    fi
    git config --global color.ui false || true
}

repo_supports() { # $1 = subcommand, $2 = flag
    repo "$1" --help >/dev/null 2>&1 || return 1
    repo "$1" --help 2>&1 | grep -q -- "$2"
}

write_local_manifest_note() {
    mkdir -p "$SRC/.repo/local_manifests"
    cat >"$SRC/.repo/local_manifests/README-bf61.xml" <<'XML'
<?xml version="1.0" encoding="UTF-8"?>
<!-- device/famue/bf61 is intentionally NOT a repo project.
     ci/build.sh materialises it from $DEVICE_TREE_SRC at $DEVICE_TREE_REV
     (the exact pushed commit) when running in CI, or git-fetches
     $DEVICE_TREE_URL for local runs. Do not add it here: a repo-managed
     clone would follow the default branch instead of the built commit. -->
<manifest></manifest>
XML
}

do_repo_sync() {
    local -a extra=()
    if repo_supports sync --optimized-fetch; then extra+=(--optimized-fetch); fi
    local -a depth=()
    if repo_supports init --depth; then depth+=(--depth=1); fi

    cd "$SRC"
    if [ ! -d .repo ]; then
        say "repo init -u $TWRP_MANIFEST -b $TWRP_BRANCH ${depth[*]:-} --no-clone-bundle"
        repo init -u "$TWRP_MANIFEST" -b "$TWRP_BRANCH" ${depth[@]+"${depth[@]}"} --no-clone-bundle ||
            die 4 "repo init 失败"
    else
        say "已有 .repo，跳过 repo init（增量 sync）"
    fi
    write_local_manifest_note

    local attempt rc
    for attempt in 1 2; do
        say "repo sync (第 ${attempt}/2 次): -c -j${JOBS} --force-sync --no-clone-bundle --no-tags ${extra[*]:-}"
        set +e
        repo sync -c -j"$JOBS" --force-sync --no-clone-bundle --no-tags ${extra[@]+"${extra[@]}"} \
            2>&1 | tee "$LOG_DIR/sync.log"
        rc=${PIPESTATUS[0]}
        set -e
        if [ "$rc" -eq 0 ]; then
            say "repo sync 成功"
            return 0
        fi
        warn "repo sync 失败 (rc=$rc)，$([ "$attempt" -eq 1 ] && echo '5 秒后重试一次' || echo '已达最大重试次数')"
        if [ "$attempt" -eq 2 ]; then die 4 "repo sync 连续 2 次失败，见 $LOG_DIR/sync.log"; fi
        sleep 5
    done
}

stage_sync() {
    group "sync: $TWRP_BRANCH (depth=1, -c, --optimized-fetch)"
    ensure_repo
    git_identity
    local t0=$SECONDS
    do_repo_sync
    say "sync 用时 $((SECONDS - t0))s ; 源码 $(du_mb "$SRC")MB ; 可用 $(free_gb "$SRC")GB"

    local free_after
    free_after=$(free_gb "$SRC"); free_after=${free_after:-0}
    if [ "$free_after" -lt "$MIN_FREE_GB_AFTER_SYNC" ] && [ "$RECLAIM_DOT_REPO" = "1" ] &&
        [ -d "$SRC/.repo/project-objects" ]; then
        local before_mb after_mb
        before_mb=$(du_mb "$SRC/.repo")
        say "可用 ${free_after}GB < ${MIN_FREE_GB_AFTER_SYNC}GB -> 回收 .repo/project-objects（git 对象，构建路径不会再用 repo/git）"
        rm -rf "$SRC/.repo/project-objects"
        after_mb=$(du_mb "$SRC/.repo")
        say ".repo ${before_mb}MB -> ${after_mb}MB ; 可用 $(free_gb "$SRC")GB（注意: 回收后不要再 repo sync）"
        free_after=$(free_gb "$SRC"); free_after=${free_after:-0}
    fi

    if [ "$free_after" -lt "$MIN_FREE_GB_BEFORE_BUILD" ]; then
        if [ "${ALLOW_TIGHT_DISK:-0}" = "1" ]; then
            warn "ALLOW_TIGHT_DISK=1: 构建前可用仅 ${free_after}GB"
        else
            die 4 "构建前磁盘不足: ${free_after}GB < ${MIN_FREE_GB_BEFORE_BUILD}GB（out/ 一般要 15-25GB）。减 SWAP_GB、清 out/、或换更大磁盘/自托管 runner"
        fi
    fi
    endgroup
}

# ------------------------------------------------------------------- tree ---
fetch_tree() {
    local dest=$1
    rm -rf "$dest"
    mkdir -p "$dest"
    say "本地模式: git fetch 设备树 $DEVICE_TREE_URL ref=${DEVICE_TREE_REV:-$DEVICE_TREE_BRANCH}"
    git -C "$dest" init -q || die 5 "git init 失败: $dest"
    git -C "$dest" remote add origin "$DEVICE_TREE_URL" 2>/dev/null ||
        git -C "$dest" remote set-url origin "$DEVICE_TREE_URL"
    local ref=${DEVICE_TREE_REV:-$DEVICE_TREE_BRANCH} rc
    set +e
    git -C "$dest" fetch --depth=1 origin "$ref" 2>&1 | tee "$LOG_DIR/tree-fetch.log"
    rc=${PIPESTATUS[0]}
    set -e
    if [ "$rc" -ne 0 ]; then
        warn "按 $ref 直接 fetch 失败（GitHub 可能不允许取 unadvertised object），退回分支 $DEVICE_TREE_BRANCH"
        git -C "$dest" fetch --depth=1 origin "$DEVICE_TREE_BRANCH" 2>&1 | tee -a "$LOG_DIR/tree-fetch.log" ||
            die 5 "git fetch 设备树失败，见 $LOG_DIR/tree-fetch.log"
    fi
    git -C "$dest" checkout -q --detach FETCH_HEAD || die 5 "git checkout 设备树失败"
}

board_var() { # $1 = make variable name, $2 = BoardConfig.mk
    local f=${2:-$SRC/$DEVICE_TREE_PATH/BoardConfig.mk}
    [ -f "$f" ] || return 0
    grep -E "^[[:space:]]*$1[[:space:]]*[+:?]?=" "$f" 2>/dev/null | head -1 |
        sed -E "s/^[^=]*=[[:space:]]*//; s/[[:space:]]+#.*$//; s/^[\"']//; s/[\"']$//" || true
}

load_boardconfig_overrides() {
    local f="$SRC/$DEVICE_TREE_PATH/BoardConfig.mk"
    [ -f "$f" ] || return 0
    local v
    v=$(board_var BOARD_BOOTIMAGE_PARTITION_SIZE "$f")
    if is_uint "$v"; then
        if [ "$v" != "$BOOT_PARTITION_SIZE" ]; then
            warn "BoardConfig BOARD_BOOTIMAGE_PARTITION_SIZE=$v 与 env 的 $BOOT_PARTITION_SIZE 不同，采用 BoardConfig"
        fi
        BOOT_PARTITION_SIZE=$v
    fi
    v=$(board_var BOARD_BOOTIMG_HEADER_VERSION "$f")
    is_uint "$v" && BOOT_HEADER_VERSION=$v
    v=$(board_var BOARD_BOOT_HEADER_VERSION "$f")
    is_uint "$v" && BOOT_HEADER_VERSION=$v
    v=$(board_var BOARD_KERNEL_PAGESIZE "$f")
    is_uint "$v" && BOOT_PAGE_SIZE=$v
    v=$(board_var BOARD_KERNEL_CMDLINE "$f")
    [ -n "$v" ] && BOOT_CMDLINE_EXPECT=$v
    return 0
}

verify_tree_commit() {
    local dest=$1 got
    got=$(git -C "$dest" rev-parse HEAD 2>/dev/null || true)
    if [ -z "$got" ]; then
        warn "设备树不是 git 仓库（无 .git），无法校验提交 —— 仅影响溯源，不影响构建"
    elif [ -n "$DEVICE_TREE_REV" ]; then
        if [ "$got" != "$DEVICE_TREE_REV" ]; then
            die 5 "设备树提交不匹配: HEAD=$got 期望=$DEVICE_TREE_REV（典型原因: 拉了默认分支而不是被推送的 commit）"
        fi
        say "设备树提交校验通过: $got"
    else
        say "设备树 HEAD=$got（未指定 DEVICE_TREE_REV）"
    fi
    local dirty=0
    if [ -d "$dest/.git" ]; then
        dirty=$(git -C "$dest" status --porcelain 2>/dev/null | wc -l | tr -d ' ')
        [ -n "$dirty" ] || dirty=0
        if [ "$dirty" != "0" ]; then warn "设备树有 $dirty 处未提交改动（本地调试属正常）"; fi
    fi
    {
        printf 'commit=%s\n' "${got:-unknown}"
        printf 'subject=%s\n' "$(git -C "$dest" log -1 --pretty=%s 2>/dev/null || echo '(no git)')"
        printf 'dirty_files=%s\n' "$dirty"
        printf 'rev_requested=%s\n' "${DEVICE_TREE_REV:-${DEVICE_TREE_BRANCH:-}}"
        printf 'source=%s\n' "${DEVICE_TREE_SRC:-$DEVICE_TREE_URL}"
        printf 'materialized_to=%s\n' "$dest"
    } >"$LOG_DIR/tree-info.txt"
}

inspect_tree() {
    local dest=$1 f
    local -a req=(BoardConfig.mk AndroidProducts.mk "twrp_${DEVICE}.mk" recovery.fstab "$PREBUILT_KERNEL" "$PREBUILT_DTB")
    for f in "${req[@]}"; do
        [ -f "$dest/$f" ] || die 5 "设备树缺少必需文件: $f"
    done
    local ksize
    ksize=$(stat -c %s "$dest/$PREBUILT_KERNEL" 2>/dev/null || echo 0)
    is_uint "$ksize" || ksize=0
    if [ "$ksize" -lt 1048576 ]; then die 5 "$PREBUILT_KERNEL 只有 ${ksize}B（<1MB），不像 11.46MB 的 gzip 内核"; fi
    local magic
    magic=$(od -An -tx1 -N2 "$dest/$PREBUILT_KERNEL" 2>/dev/null | tr -d ' \n' || true)
    if [ "$magic" != "1f8b" ]; then
        warn "$PREBUILT_KERNEL 头两字节是 $magic（不是 gzip 1f8b）；BOARD_KERNEL_IMAGE_NAME=Image.gz 时 mkbootimg 仍能打包，但请确认"
    fi
    local dsize dbsize
    dsize=$(stat -c %s "$dest/$PREBUILT_DTB" 2>/dev/null || echo 0)
    say "prebuilt: kernel=${ksize}B dtb=${dsize}B"
    if [ -f "$dest/$PREBUILT_DTBO" ]; then
        dbsize=$(stat -c %s "$dest/$PREBUILT_DTBO" 2>/dev/null || echo 0)
        say "prebuilt: dtbo=${dbsize}B"
        if [ "$dbsize" = "8388608" ]; then
            say "note: prebuilt/dtbo.img 是 8MiB 整分区 dump（不是 trimmed dtbo），bootimage 目标不消费它"
        fi
    else
        warn "缺少 $PREBUILT_DTBO（BOARD_PREBUILT_DTBOIMAGE），dtbo.img 目标会失败；bootimage 目标不受影响"
    fi
    load_boardconfig_overrides
    say "BoardConfig 采用值: boot 分区=${BOOT_PARTITION_SIZE}B header=v${BOOT_HEADER_VERSION} pagesize=${BOOT_PAGE_SIZE}"
    say "BoardConfig cmdline 期望: ${BOOT_CMDLINE_EXPECT:-（空）}"
    if grep -qF -- "$LUNCH_TARGET" "$dest/AndroidProducts.mk" 2>/dev/null; then
        say "lunch 目标 $LUNCH_TARGET 在 AndroidProducts.mk 中"
    else
        warn "AndroidProducts.mk 里没找到 $LUNCH_TARGET（若来自继承树可忽略；lunch 后会再校验 TARGET_PRODUCT）"
    fi
}

run_check_tree() {
    local dest=$1 target="" rc
    if [ "$SKIP_CHECK_TREE" = "1" ]; then
        warn "SKIP_CHECK_TREE=1: 跳过 $CHECK_TREE_SCRIPT（不建议在 CI 上跳过）"
        return 0
    fi
    if [ -f "$dest/$CHECK_TREE_SCRIPT" ]; then
        target=$dest
    elif [ -n "$DEVICE_TREE_SRC" ] && [ -f "$DEVICE_TREE_SRC/$CHECK_TREE_SCRIPT" ]; then
        target=$DEVICE_TREE_SRC
    fi
    if [ -z "$target" ]; then
        die 5 "找不到门禁脚本 $CHECK_TREE_SCRIPT（设备树里没有它；确认已提交，或临时 SKIP_CHECK_TREE=1）"
    fi
    say "运行门禁: (cd $target && bash $CHECK_TREE_SCRIPT)"
    set +e
    (cd "$target" && bash "$CHECK_TREE_SCRIPT") 2>&1 | tee "$LOG_DIR/check-tree.log"
    rc=${PIPESTATUS[0]}
    set -e
    if [ "$rc" -ne 0 ]; then
        tail -40 "$LOG_DIR/check-tree.log" >&2 || true
        die 5 "$CHECK_TREE_SCRIPT 失败 (rc=$rc)，完整输出: $LOG_DIR/check-tree.log"
    fi
    say "门禁通过: $CHECK_TREE_SCRIPT"
}

stage_tree() {
    local dest="$SRC/$DEVICE_TREE_PATH"
    group "device tree: ${DEVICE_TREE_PATH} @ ${DEVICE_TREE_REV:-${DEVICE_TREE_BRANCH:-local}}"
    [ -d "$SRC/build" ] || warn "源码树还没有 build/（先跑 sync stage？）"
    mkdir -p "$(dirname -- "$dest")"

    if [ -n "$DEVICE_TREE_SRC" ]; then
        [ -d "$DEVICE_TREE_SRC" ] || die 5 "DEVICE_TREE_SRC=$DEVICE_TREE_SRC 不存在"
        local rsrc rdest=""
        rsrc=$(readlink -f -- "$DEVICE_TREE_SRC")
        if [ -e "$dest" ]; then rdest=$(readlink -f -- "$dest" || true); fi
        if [ "$rsrc" = "$rdest" ]; then
            say "设备树已在目标位置 $dest，跳过复制"
        else
            mkdir -p "$dest"
            if command -v rsync >/dev/null 2>&1; then
                say "rsync $rsrc/ -> $dest/ （排除 work/out/.ccache/本地 dump）"
                rsync -a --delete \
                    --exclude '/work/' --exclude '/out/' --exclude '/.ccache/' \
                    --exclude '/bf61_backup/' --exclude '/extract/' --exclude '/rescue_kit/' \
                    --exclude '/build.log' --exclude '*.rar' \
                    "$rsrc/" "$dest/" || die 5 "rsync 设备树失败"
            else
                say "rsync 缺失，退回 cp -a $rsrc/ -> $dest/（先清空目标）"
                rm -rf "$dest"
                mkdir -p "$dest"
                cp -a "$rsrc/." "$dest/" || die 5 "cp -a 设备树失败"
                rm -rf "$dest/work" "$dest/out" "$dest/.ccache" "$dest/bf61_backup" \
                       "$dest/extract" "$dest/rescue_kit"
            fi
        fi
    else
        fetch_tree "$dest"
    fi

    verify_tree_commit "$dest"
    inspect_tree "$dest"
    run_check_tree "$dest"
    endgroup
}

# ----------------------------------------------------------------- ccache ---
stage_ccache() {
    group "ccache (可选)"
    if [ "$CCACHE_ENABLE" != "1" ]; then
        say "ccache 关闭 (CCACHE_ENABLE=$CCACHE_ENABLE)"
        endgroup
        return 0
    fi
    if ! command -v ccache >/dev/null 2>&1; then
        warn "ccache 未安装，跳过（它只加速 make/kati 编的目标，soong 主体不受益）"
        endgroup
        return 0
    fi
    setup_ccache_env
    mkdir -p "$CCACHE_DIR"
    ccache -M "$CCACHE_SIZE" >/dev/null 2>&1 || warn "ccache -M $CCACHE_SIZE 失败"
    ccache -z >/dev/null 2>&1 || true
    say "ccache dir=$CCACHE_DIR max=$CCACHE_SIZE exec=$CCACHE_EXEC"
    ccache -s 2>/dev/null | sed 's/^/    /' || true
    endgroup
}

# ------------------------------------------------------------------ build ---
MEM_WATCH_PID=""
start_mem_watch() {
    : >"$LOG_DIR/mem-timeline.log"
    (
        while :; do
            printf '%s ' "$(date -u +%H:%M:%S)"
            awk '/^MemTotal:/{t=$2}/^MemAvailable:/{a=$2}/^SwapTotal:/{s=$2}/^SwapFree:/{f=$2}/^Committed_AS:/{c=$2}END{printf "ram=%dM avail=%dM swap_used=%dM committed=%dM\n", t/1024, a/1024, (s-f)/1024, c/1024}' /proc/meminfo
            sleep 30
        done
    ) >>"$LOG_DIR/mem-timeline.log" 2>&1 &
    MEM_WATCH_PID=$!
}
stop_mem_watch() {
    if [ -n "${MEM_WATCH_PID:-}" ]; then
        kill "$MEM_WATCH_PID" 2>/dev/null || true
        wait "$MEM_WATCH_PID" 2>/dev/null || true
        MEM_WATCH_PID=""
    fi
}

collect_diagnostics() {
    local why=${1:-build} logf="$WORK/build.log" report="$LOG_DIR/oom-report.txt"
    local tag="UNKNOWN" dmesg_txt="" oom_sig=""
    if [ -f "$logf" ]; then
        if grep -qiE 'No space left on device|ENOSPC' "$logf"; then
            tag="DISK_FULL"
        elif grep -qiE 'posix_spawn: Cannot allocate memory|out of memory|Killed signal|cc1plus: out of memory|internal compiler error: Killed|ninja: fatal: posix_spawn' "$logf"; then
            tag="OOM"
        elif grep -qiE 'FAILED: |error:' "$logf"; then
            tag="BUILD_ERROR"
        fi
        oom_sig=$(grep -nE 'No space left on device|posix_spawn: Cannot allocate memory|Killed signal|cc1plus: out of memory|FAILED: ' "$logf" 2>/dev/null | tail -40 || true)
    fi
    dmesg_txt=$({ dmesg 2>/dev/null || sudo -n dmesg 2>/dev/null || true; } | grep -iE 'killed process|out of memory|oom-kill|oom_reaper' | tail -20 || true)
    if [ -n "$dmesg_txt" ] && [ "$tag" = "BUILD_ERROR" ]; then tag="OOM"; fi

    {
        printf '=== BF61 CI diagnostics (%s) ===\n' "$why"
        printf 'time: %s\n' "$(date -u)"
        printf 'classification: %s\n\n' "$tag"
        printf -- '--- uname ---\n'; uname -a
        printf -- '--- free -h ---\n'; free -h
        printf -- '--- swapon --show ---\n'; swapon --show 2>/dev/null || true
        printf -- '--- meminfo ---\n'; grep -E '^(MemTotal|MemFree|MemAvailable|SwapTotal|SwapFree|Committed_AS):' /proc/meminfo || true
        printf -- '--- df -h ---\n'; df -h
        printf -- '--- vmstat 1 2 ---\n'; vmstat 1 2 || true
        printf -- '--- dmesg OOM ---\n'; printf '%s\n' "${dmesg_txt:-(none)}"
        printf -- '\n--- build.log OOM/ENOSPC signatures ---\n'; printf '%s\n' "${oom_sig:-(none)}"
        printf -- '\n--- build.log tail ---\n'; tail -60 "$logf" 2>/dev/null || true
        printf -- '\n--- mem-timeline tail ---\n'; tail -20 "$LOG_DIR/mem-timeline.log" 2>/dev/null || true
    } >"$report" 2>&1 || true

    say "失败分类: $tag（诊断写入 $report）"
    case "$tag" in
        OOM)
            say "处理: JOBS 降到 2-4、确认 swap 已开(swapon --show)、NINJA_HIGHMEM_NUM_JOBS=2；不要用 nproc 当 JOBS"
            ;;
        DISK_FULL)
            say "处理: 确认清盘步骤没把 swap 删掉（swap-storage=false）；SWAP_GB 降到 4；清 out/target/common/obj；换更大磁盘/自托管"
            ;;
        BUILD_ERROR)
            say "处理: 看 build.log 第一个 FAILED:/error:；常见原因是 ALLOW_MISSING_DEPENDENCIES 未生效、fstab 解析、TW_* 开关拼写"
            ;;
        *)
            say "处理: 看 build.log 首个错误"
            ;;
    esac
    free -h 2>/dev/null || true
    df -h 2>/dev/null | tail -5 || true
    tail -40 "$logf" 2>&1 || true
}

stage_build() {
    group "mka $BUILD_TARGET (lunch $LUNCH_TARGET)"
    [ -d "$SRC/build" ] || die 6 "源码树不完整: $SRC/build 不存在，先跑 sync"
    [ -f "$SRC/$DEVICE_TREE_PATH/BoardConfig.mk" ] || die 6 "设备树不在 $SRC/$DEVICE_TREE_PATH，先跑 tree"
    load_boardconfig_overrides
    if [ "$CCACHE_ENABLE" = "1" ]; then setup_ccache_env; fi

    export ALLOW_MISSING_DEPENDENCIES="${ALLOW_MISSING_DEPENDENCIES:-true}"
    export LC_ALL=C
    export NINJA_HIGHMEM_NUM_JOBS JOBS

    cd "$SRC"
    local free_now
    free_now=$(free_gb "$SRC"); free_now=${free_now:-0}
    say "构建前可用磁盘 ${free_now}GB，swap ${SWAP_NOW_GB}GB，JOBS=$JOBS"
    if [ "$free_now" -lt "$MIN_FREE_GB_BEFORE_BUILD" ] && [ "$RECLAIM_DOT_REPO" = "1" ] &&
        [ -d .repo/project-objects ]; then
        say "回收 .repo/project-objects 以腾出空间"
        rm -rf .repo/project-objects
        free_now=$(free_gb "$SRC"); free_now=${free_now:-0}
        say "回收后可用 ${free_now}GB"
    fi
    if [ "$free_now" -lt "$MIN_FREE_GB_BEFORE_BUILD" ] && [ "${ALLOW_TIGHT_DISK:-0}" != "1" ]; then
        die 6 "构建前磁盘不足: ${free_now}GB < ${MIN_FREE_GB_BEFORE_BUILD}GB"
    fi

    start_mem_watch

    set +u
    # shellcheck disable=SC1091
    if ! . build/envsetup.sh >"$LOG_DIR/envsetup.log" 2>&1; then
        stop_mem_watch; set -u
        die 6 "source build/envsetup.sh 失败（见 $LOG_DIR/envsetup.log）"
    fi
    if ! lunch "$LUNCH_TARGET" >"$LOG_DIR/lunch.log" 2>&1; then
        stop_mem_watch; set -u
        tail -30 "$LOG_DIR/lunch.log" >&2 || true
        die 6 "lunch $LUNCH_TARGET 失败（ALLOW_MISSING_DEPENDENCIES / COMMON_LUNCH_CHOICES？）"
    fi
    set -u

    local want_product="${LUNCH_TARGET%-*}"
    say "TARGET_PRODUCT=${TARGET_PRODUCT:-?} TARGET_DEVICE=${TARGET_DEVICE:-?} TARGET_BUILD_VARIANT=${TARGET_BUILD_VARIANT:-?}"
    if [ "${TARGET_PRODUCT:-}" != "$want_product" ]; then
        stop_mem_watch
        die 6 "lunch 结果异常: TARGET_PRODUCT=${TARGET_PRODUCT:-<empty>} 期望=$want_product"
    fi

    local t0=$SECONDS rc
    set +e
    mka "$BUILD_TARGET" -j"$JOBS" 2>&1 | tee "$WORK/build.log"
    rc=${PIPESTATUS[0]}
    set -e
    stop_mem_watch
    say "mka 退出码=$rc 用时=$((SECONDS - t0))s 日志=$WORK/build.log"
    if [ "$rc" -ne 0 ]; then
        collect_diagnostics "mka rc=$rc"
        exit 6
    fi
    local out="$SRC/out/target/product/$DEVICE"
    say "out 体积: $(du_mb "$SRC/out")MB ; boot.img=$(stat -c %s "$out/boot.img" 2>/dev/null || echo missing)B"
    ccache -s 2>/dev/null | sed 's/^/    /' || true
    endgroup
}

# ----------------------------------------------------------------- verify ---
stage_verify() {
    local out="$SRC/out/target/product/$DEVICE"
    group "verify: $out/boot.img"
    load_boardconfig_overrides
    local img="$out/boot.img"
    if [ ! -f "$img" ]; then
        die 7 "缺少 $img —— BUILD_TARGET=$BUILD_TARGET 与设备形态不匹配？(A/B recovery-as-boot 必须用 bootimage)"
    fi
    local rep="$LOG_DIR/bootimg-info.txt"
    local rc
    set +e
    IMG="$img" \
        REPORT="$rep" \
        EXPECT_PAGE_SIZE="$BOOT_PAGE_SIZE" \
        EXPECT_HEADER_VERSION="$BOOT_HEADER_VERSION" \
        EXPECT_KERNEL="$SRC/$DEVICE_TREE_PATH/$PREBUILT_KERNEL" \
        EXPECT_DTB="$SRC/$DEVICE_TREE_PATH/$PREBUILT_DTB" \
        PARTITION_SIZE="$BOOT_PARTITION_SIZE" \
        CMDLINE_EXPECT="$BOOT_CMDLINE_EXPECT" \
        EXPECT_KERNEL_MAGIC="$EXPECT_KERNEL_MAGIC" \
        WARN_RATIO="$BOOT_SIZE_WARN_RATIO" \
        STRICT_RAMDISK="$STRICT_RAMDISK" \
        python3 - <<'PY'
import gzip, os, struct, subprocess, sys
from datetime import datetime, timezone

E = os.environ
img_path = E["IMG"]
report_path = E["REPORT"]
lines, fails, warns = [], [], []

def add(kind, msg):
    lines.append("[%s] %s" % (kind, msg))
    if kind == "FAIL":
        fails.append(msg)
    elif kind == "WARN":
        warns.append(msg)

def as_int(name, default):
    try:
        return int(E.get(name, "") or default)
    except ValueError:
        return default

part_size = as_int("PARTITION_SIZE", 0)
page_expect = as_int("EXPECT_PAGE_SIZE", 0)
hdr_expect = as_int("EXPECT_HEADER_VERSION", 0)
warn_ratio = float(E.get("WARN_RATIO") or 0.94)
strict_ramdisk = (E.get("STRICT_RAMDISK") or "1") == "1"

def finish():
    head = "boot.img 校验报告  %s" % datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    body = "%s\n%s\n%s\n" % (head, "-" * len(head), "\n".join(lines))
    verdict = "PASS" if not fails else "FAIL"
    body += "\nverdict: %s  (fail=%d warn=%d)\n" % (verdict, len(fails), len(warns))
    try:
        with open(report_path, "w") as fh:
            fh.write(body)
    except OSError as exc:
        print("cannot write report: %s" % exc)
    sys.stdout.write(body)
    sys.exit(1 if fails else 0)

with open(img_path, "rb") as fh:
    data = fh.read()
n = len(data)
add("INFO", "file=%s size=%d (%0.2f MiB)" % (img_path, n, n / 1048576.0))
if n < 1660:
    add("FAIL", "文件只有 %d 字节，比 header v2 (1660B) 还短" % n)
    finish()
if data[:8] != b"ANDROID!":
    add("FAIL", "boot magic=%r，期望 b'ANDROID!'" % data[:8])
    finish()

u32 = lambda o: struct.unpack_from("<I", data, o)[0]
u64 = lambda o: struct.unpack_from("<Q", data, o)[0]
kernel_size, kernel_addr = u32(8), u32(12)
ramdisk_size, ramdisk_addr = u32(16), u32(20)
second_size, second_addr = u32(24), u32(28)
tags_addr, page_size = u32(32), u32(36)
header_version, os_version = u32(40), u32(44)
name = data[48:64].split(b"\0")[0].decode("utf-8", "replace")
cmdline = data[64:576].split(b"\0")[0].decode("utf-8", "replace")
extra_cmdline = data[608:1632].split(b"\0")[0].decode("utf-8", "replace")
recovery_dtbo_size = u32(1632)
header_size = u32(1644) if header_version >= 1 else 0
dtb_size, dtb_addr = u32(1648), u64(1652)

add("INFO", "header_version=%d page_size=%d header_size=%d name=%r" % (header_version, page_size, header_size, name))
add("INFO", "os_version=0x%08x tags_addr=0x%08x" % (os_version, tags_addr))
add("INFO", "kernel: size=%d addr=0x%08x" % (kernel_size, kernel_addr))
add("INFO", "ramdisk: size=%d addr=0x%08x" % (ramdisk_size, ramdisk_addr))
add("INFO", "second: size=%d addr=0x%08x" % (second_size, second_addr))
if header_version >= 2:
    add("INFO", "dtb: size=%d addr=0x%016x" % (dtb_size, dtb_addr))
else:
    add("INFO", "recovery_dtbo: size=%d（header v1）" % recovery_dtbo_size)
add("INFO", "cmdline=%r" % cmdline)
if extra_cmdline:
    add("INFO", "extra_cmdline=%r" % extra_cmdline)

if page_expect and page_size != page_expect:
    add("FAIL", "page_size=%d，BoardConfig 期望 %d" % (page_size, page_expect))
if hdr_expect and header_version != hdr_expect:
    add("FAIL", "header_version=%d，BoardConfig 期望 %d" % (header_version, hdr_expect))
if page_size < 512 or page_size > 65536 or (page_size & (page_size - 1)) != 0:
    add("FAIL", "page_size=%d 不是合法 2 的幂" % page_size)
    finish()

def pages(x):
    return (x + page_size - 1) // page_size

off = page_size
k_off = off; off += pages(kernel_size) * page_size
r_off = off; off += pages(ramdisk_size) * page_size
s_off = off; off += pages(second_size) * page_size
dtb_off = dtbo_off = 0
if header_version == 1:
    dtbo_off = off; off += pages(recovery_dtbo_size) * page_size
elif header_version >= 2:
    dtb_off = off; off += pages(dtb_size) * page_size
computed = off

if second_size:
    add("WARN", "second stage 非空 (%d B)，MTK boot v2 一般不使用" % second_size)

kp = E.get("EXPECT_KERNEL") or ""
if kp and os.path.isfile(kp):
    want = os.path.getsize(kp)
    if want != kernel_size:
        add("FAIL", "kernel_size=%d 与 %s (%d) 不一致 —— 镜像里不是这棵树的 prebuilt 内核" % (kernel_size, kp, want))
    else:
        add("PASS", "kernel 段大小 == prebuilt kernel (%d B)" % want)
else:
    add("WARN", "找不到 prebuilt kernel (%s)，跳过内核大小比对" % kp)

kmagic = data[k_off:k_off + 2]
if E.get("EXPECT_KERNEL_MAGIC") == "gzip" and kmagic != b"\x1f\x8b":
    add("FAIL", "kernel 段头 %r 不是 gzip (1f8b)" % kmagic)
elif E.get("EXPECT_KERNEL_MAGIC") == "gzip":
    add("PASS", "kernel 段是 gzip")

if header_version >= 2:
    dp = E.get("EXPECT_DTB") or ""
    if dp and os.path.isfile(dp):
        want = os.path.getsize(dp)
        if want != dtb_size:
            add("FAIL", "dtb_size=%d 与 %s (%d) 不一致 —— dtb 没被 --dtb 打进 boot.img" % (dtb_size, dp, want))
        else:
            add("PASS", "dtb 段大小 == prebuilt dtb (%d B)" % want)
    if dtb_size:
        magic = data[dtb_off:dtb_off + 4]
        if magic == b"\xd7\xb7\xab\x1e":
            add("PASS", "dtb 段是 MTK DTBO 容器 (0xd7b7ab1e)")
        elif magic == b"\xd0\x0d\xfe\xed":
            add("PASS", "dtb 段是纯 FDT (0xd00dfeed)")
        else:
            add("WARN", "dtb 段 magic=%r 不识别" % magic)

if part_size:
    if computed > part_size:
        add("FAIL", "镜像需要 %d B > 分区 %d B（超出 %d B）—— 必须缩 ramdisk/内核" % (computed, part_size, computed - part_size))
    elif computed > part_size * warn_ratio:
        add("WARN", "占用分区 %0.1f%% (需要 %d / 可用 %d)，余量不足" % (100.0 * computed / part_size, computed, part_size))
    else:
        add("PASS", "镜像 %d B，分区 %d B，余量 %d B (%0.1f%%)" % (computed, part_size, part_size - computed, 100.0 * (part_size - computed) / part_size))
if n < computed:
    add("FAIL", "文件被截断: 实际 %d B < header 推算 %d B" % (n, computed))
elif n > computed:
    add("WARN", "文件比 header 推算多 %d B（footer/padding？）" % (n - computed))

want_cmd = (E.get("CMDLINE_EXPECT") or "").strip()
if want_cmd:
    if want_cmd not in cmdline:
        add("FAIL", "cmdline 不含 %r（实际 %r）" % (want_cmd, cmdline))
    else:
        add("PASS", "cmdline 含 %r" % want_cmd)

rd = data[r_off:r_off + ramdisk_size]
kind = "unknown"
raw = None
if rd[:2] == b"\x1f\x8b":
    kind = "gzip"
    try:
        raw = gzip.decompress(rd)
    except Exception as exc:  # noqa: BLE001
        add("FAIL", "ramdisk gzip 解压失败: %s（镜像可能被截断）" % exc)
elif rd[:4] == b"\x04\x22\x4d\x18":
    kind = "lz4"
    try:
        proc = subprocess.run(["lz4", "-d", "-c"], input=rd, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        if proc.returncode == 0:
            raw = proc.stdout
        else:
            add("WARN", "lz4 解压失败（安装 liblz4-tool 可校验 ramdisk 内容）")
    except FileNotFoundError:
        add("WARN", "ramdisk 是 lz4，但本机没有 lz4 命令，跳过 payload 校验")
elif rd[:6] in (b"070701", b"070702"):
    kind = "cpio"
    raw = rd
else:
    add("WARN", "ramdisk 压缩格式不识别: %r" % rd[:8])
add("INFO", "ramdisk 压缩格式=%s，解压后 %s B" % (kind, len(raw) if raw else "?"))

def parse_cpio(buf):
    names, i, total = [], 0, len(buf)
    while i + 110 <= total:
        if buf[i:i + 6] not in (b"070701", b"070702"):
            return None, "cpio magic 异常 @%d: %r" % (i, buf[i:i + 6])
        try:
            filesize = int(buf[i + 54:i + 62], 16)
            namesize = int(buf[i + 94:i + 102], 16)
        except ValueError:
            return None, "cpio 头部字段解析失败 @%d" % i
        name_start = i + 110
        name = buf[name_start:name_start + namesize - 1].decode("utf-8", "replace")
        j = name_start + namesize
        j += (-j) % 4
        j += filesize
        j += (-j) % 4
        if name == "TRAILER!!!":
            break
        names.append(name)
        i = j
    return names, None

if raw:
    names, err = parse_cpio(raw)
    if err:
        add("WARN", "ramdisk cpio 解析问题: %s" % err)
    if names:
        add("INFO", "ramdisk 条目数=%d" % len(names))
        tops = sorted({p.split("/")[0] for p in names if p})
        add("INFO", "ramdisk 顶层=%s" % ", ".join(tops[:12]))
        has_recovery = any(p in ("sbin/recovery", "system/bin/recovery", "system/bin/recovery.bin") for p in names)
        has_fstab = any(p.endswith("etc/recovery.fstab") for p in names)
        has_twres = any(p.startswith("twres") or "/twres/" in p for p in names)
        has_twrpflags = any(p.endswith("etc/twrp.flags") for p in names)
        add("PASS" if has_recovery else ("FAIL" if strict_ramdisk else "WARN"),
            "ramdisk 里的 recovery 二进制: %s" % ("sbin/recovery|system/bin/recovery" if has_recovery else "缺失"))
        add("PASS" if has_fstab else ("FAIL" if strict_ramdisk else "WARN"),
            "ramdisk 里的 recovery.fstab: %s" % ("有" if has_fstab else "缺失"))
        add("PASS" if has_twres else ("FAIL" if strict_ramdisk else "WARN"),
            "ramdisk 里的 twres/ 主题资源: %s" % ("有" if has_twres else "缺失"))
        add("INFO", "ramdisk 里的 /etc/twrp.flags: %s" % ("有" if has_twrpflags else "无（本设备树尚未提供）"))

finish()
PY
    rc=$?
    set -e
    if [ "$rc" -ne 0 ]; then
        die 7 "boot.img 校验失败（报告: $rep）"
    fi
    say "boot.img 校验通过（报告: $rep）"
    endgroup
}

# ---------------------------------------------------------------- package ---
stage_package() {
    group "package artifacts -> $ART"
    mkdir -p "$ART"
    local out="$SRC/out/target/product/$DEVICE"
    local have_img=0

    if [ -f "$out/boot.img" ]; then
        cp -f "$out/boot.img" "$ART/boot.img"
        have_img=1
        say "boot.img -> $ART/boot.img ($(stat -c %s "$ART/boot.img")B)"
    else
        warn "没有 $out/boot.img"
    fi

    local f
    for f in "$WORK/build.log" "$LOG_DIR/driver.log" "$LOG_DIR/check-tree.log" "$LOG_DIR/sync.log" \
        "$LOG_DIR/tree-info.txt" "$LOG_DIR/bootimg-info.txt" "$LOG_DIR/oom-report.txt" \
        "$LOG_DIR/mem-timeline.log" "$LOG_DIR/envsetup.log" "$LOG_DIR/lunch.log" \
        "$LOG_DIR/tree-fetch.log" "$LOG_DIR/context.txt"; do
        if [ -f "$f" ]; then cp -f "$f" "$ART/"; fi
    done

    local cand
    for cand in "$out/recovery.log" "$WORK/recovery.log" "$SRC/recovery.log" /tmp/recovery.log; do
        if [ -f "$cand" ]; then
            cp -f "$cand" "$ART/recovery.log"
            say "recovery.log <- $cand"
            break
        fi
    done
    if [ ! -f "$ART/recovery.log" ]; then
        say "recovery.log: 无（构建期 TWRP 不写该文件；真机首启后 adb pull /tmp/recovery.log）"
    fi

    local tree="$SRC/$DEVICE_TREE_PATH"
    for f in BoardConfig.mk AndroidProducts.mk "twrp_${DEVICE}.mk" device.mk recovery.fstab; do
        if [ -f "$tree/$f" ]; then cp -f "$tree/$f" "$ART/device-$f"; fi
    done
    local z
    for z in "$out"/*.zip; do
        if [ -f "$z" ]; then cp -f "$z" "$ART/"; fi
    done

    ( cd "$ART" && rm -f SHA256SUMS SHA256SUMS.tmp &&
        find . -maxdepth 1 -type f ! -name 'SHA256SUMS*' -printf '%f\n' | LC_ALL=C sort |
        tr '\n' '\0' | xargs -0 -r sha256sum >SHA256SUMS.tmp &&
        mv SHA256SUMS.tmp SHA256SUMS ) || warn "生成 SHA256SUMS 失败"
    say "SHA256SUMS:"; sed 's/^/    /' "$ART/SHA256SUMS" 2>/dev/null || true
    say "artifacts:"
    find "$ART" -maxdepth 1 -type f -printf '    %10s  %f\n' 2>/dev/null | LC_ALL=C sort -k2 || true

    if [ "$have_img" -ne 1 ]; then
        if [ "$PACKAGE_STRICT" = "1" ]; then
            die 8 "没有 boot.img，artifacts 只含日志（PACKAGE_STRICT=1）"
        fi
        warn "没有 boot.img，只打包了日志（构建失败时的预期行为）"
    fi
    endgroup
}

# --------------------------------------------------------------- dispatch ---
IFS=',' read -r -a STAGES <<<"$STAGES_RAW"
for _tok in "${STAGES[@]}"; do
    case "$_tok" in
        preflight | sync | tree | ccache | build | verify | package | all | "") ;;
        *) die 2 "未知 stage: '$_tok'（可用: preflight sync tree ccache build verify package all）" ;;
    esac
done
unset _tok
has_stage() {
    local s=$1 x
    for x in "${STAGES[@]}"; do
        if [ "$x" = "$s" ] || [ "$x" = "all" ]; then return 0; fi
    done
    return 1
}

trap 'stop_mem_watch 2>/dev/null || true' EXIT

say "== BF61 TWRP build driver =="
say "env=$ENV_FILE stages=$STAGES_RAW device=$DEVICE vendor=$VENDOR branch=$TWRP_BRANCH lunch=$LUNCH_TARGET target=$BUILD_TARGET"
say "RAM=${RAM_GB}GB swap=${SWAP_NOW_GB}GB vCPU=${NCPU} -> JOBS=$JOBS NINJA_HIGHMEM_NUM_JOBS=$NINJA_HIGHMEM_NUM_JOBS"
say "work=$WORK src=$SRC"

for _stage in preflight sync tree ccache build verify package; do
    if has_stage "$_stage"; then
        case "$_stage" in
            preflight) stage_preflight ;;
            sync) stage_sync ;;
            tree) stage_tree ;;
            ccache) stage_ccache ;;
            build) stage_build ;;
            verify) stage_verify ;;
            package) stage_package ;;
        esac
    fi
done

say "== done: artifacts in $ART =="
