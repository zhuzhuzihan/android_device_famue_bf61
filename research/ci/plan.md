# BF61 TWRP GitHub Actions build — design, numbers, failure modes

Famue BF61 · MT6762 (`ro.board.platform=mt6765` BSP) · Android 12 · **A/B, no recovery partition**
(`BOARD_USES_RECOVERY_AS_BOOT := true` → target `bootimage`, output `out/target/product/bf61/boot.img`,
32 MiB boot partition) · prebuilt 11 465 967 B gzip kernel · dynamic partitions · FBE v2 + metadata encryption.

Deliverables in this directory (all validated, see §9):

| file | lines | role |
|---|---|---|
| `build.yml` | 276 | complete workflow draft → `.github/workflows/build.yml` |
| `build.sh` | 1021 | build driver, local + CI shared, 7 stages, exit codes per stage |
| `bf61.env` | 81 | device/branch/target/resource/threshold variables |
| `plan.md` | this | rationale, math, failure modes, validation record |

Baseline read in full before writing: `references/17-github-actions.md` (472 lines),
`assets/workflows/twrp-build.yml`, `assets/ci/build.sh`, `assets/ci/DEVICE.env.example`.

---

## 1. What the current `.github/workflows/build.yml` does wrong

| # | line | current | consequence | fixed by |
|---|---|---|---|---|
| 1 | 57 | `git clone --depth=1 https://…/android_device_famue_bf61 device/famue/bf61` | builds **default-branch HEAD**, never `GITHUB_SHA`. `main` advanced by someone else, or a PR/pin does not build what was pushed | stage `tree` copies the checkout and hard-fails on `git rev-parse HEAD != DEVICE_TREE_REV` |
| 2 | 51 | `repo sync -c -j4 --no-tags --fail-fast` | 1 transient project error aborts the whole run, no retry; no `--force-sync` (dirty-tree death), no `--optimized-fetch` (≈30 % more traffic) | stage `sync`: `--force-sync --no-clone-bundle --no-tags --optimized-fetch` + 1 retry |
| 3 | 65 | `source build/envsetup.sh` | works only because the step has no `set -u`; the moment `set -u` is added it dies. Guide marks this the #1 "mysterious CI failure" | `set +u` / `set -u` bracketing + rc-checked `. envsetup.sh` and `lunch` |
| 4 | — | no `ALLOW_MISSING_DEPENDENCIES` | minimal manifest + `lunch` on a device tree can fail on missing deps | exported in stage `build` (value from `bf61.env`) |
| 5 | — | no swap, no memory reasoning, `-j$(nproc)` (67) | 4 vCPU / 16 GB: soong compile 4×~2.5 GB + 2 conc. highmem 6–8 GB each ⇒ peak 19–21 GB → OOM killer with `posix_spawn: Cannot allocate memory` or silent job kill | JOBS=4, `NINJA_HIGHMEM_NUM_JOBS=2`, own 8 GB swap, 30 s memory timeline |
| 6 | 16–18 | cleanup omits `/opt/hostedtoolcache` (4–7 GB) and `/var/lib/apt/lists` | ~5–7 GB of the already-thin budget wasted | full cleanup list in the "Free disk space" step |
| 7 | — | no `timeout-minutes`, no `concurrency` | 6 h runs burn minutes; two pushes build concurrently and fight for bandwidth/disk | job `timeout-minutes: 350`, `concurrency` group per ref with `cancel-in-progress` |
| 8 | 69–78 | artifact upload `if-no-files-found: warn`, no SHA/verification | green job with no `boot.img`, or an image that is 33 MB and unflashable; absolute `/home/runner/...` paths | stage `verify` (header + payload) then stage `package` (`PACKAGE_STRICT=1` on success) → `boot.img`, `build.log`, `SHA256SUMS`, `bootimg-info.txt` |
| 9 | — | no tree gate | a broken device tree is discovered after 3 h of compiling | `bash tools/check-tree.sh` (Lead-owned, non-zero = broken) inside stage `tree` |
| 10 | — | no failure diagnostics | OOM vs ENOSPC vs real compile error indistinguishable | `oom-report.txt`: classification + `free -h` + `swapon` + `df` + `vmstat` + `dmesg` OOM tail + log signatures + tail, plus a memory timeline |

---

## 2. "Build the exact pushed commit": copy the workspace, not `local_manifest`

**Decision:** `rsync` the already-checked-out workspace into `$SRC/device/famue/bf61`
(stage `tree`), then assert `git -C <dest> rev-parse HEAD == $DEVICE_TREE_REV` before anything is built.
`DEVICE_TREE_SRC=${{ github.workspace }}`, `DEVICE_TREE_REV=${{ github.sha }}`.

Why not `.repo/local_manifests/device.xml` with `revision="$GITHUB_SHA"`:

1. **PR merge commits do not exist in the device-tree remote.** On `pull_request`, `GITHUB_SHA` is
   `refs/pull/N/merge`; `repo` would try `git fetch origin <sha>` against the *device tree* remote and fail hard.
   The copy path has no such coupling.
2. **No second network round-trip** and no `--depth=1` vs SHA-fetch interaction to debug.
3. **Provenance is explicit and verifiable**: `commit=`, `subject=`, `dirty_files=` land in
   `work/logs/tree-info.txt`, an equality check gates the build, and `git rev-parse HEAD` is also asserted in
   the workflow's first step (fails if checkout were ever not `GITHUB_SHA`).
4. The `.git` directory is copied too (23 MB), so any makefile that shells out to git still works.

Fallback kept for local runs (no checkout): `fetch_tree()` does `git init && git fetch --depth=1 origin <sha> &&
git checkout --detach FETCH_HEAD`, falling back to the branch with a warning.
Verified on 2026-11-13 that GitHub **does** serve `git fetch --depth=1 origin <sha>` for a pushed commit
(`rc=0`), so the fallback is not decorative — but for PRs it is exactly the path that cannot work, which is
why CI does not use it.

A comment-only `.repo/local_manifests/README-bf61.xml` is written on purpose: it documents that
`device/famue/bf61` is **not** a repo project, so nobody "fixes" the tree back to a branch-tracking clone.

---

## 3. Memory × parallelism math (4 vCPU / 16 GB / own swap)

Guide §0.5 formula: `JOBS ≈ min(nproc, floor((RAM_GB + swap_GB) / 4))`, `soong` peak ≈ 2–3 GB per compile job,
`NINJA_HIGHMEM_NUM_JOBS` throttles the link/packaging jobs that each eat 6–8 GB.

```
nproc = 4
RAM   = 16 GB  (MemTotal 16 384 000 kB → rounds to 16)
swap  =  8 GB  (self-built, see §4)
        ─────────
effective = 24 GB  →  24/4 = 6  →  min(4, 6) = 4  ⇒  JOBS = 4
NINJA_HIGHMEM_NUM_JOBS = 2
```

Peak accounting (worst case during `mka bootimage`):

| component | concurrency | per unit | subtotal |
|---|---|---|---|
| ninja C/C++ compile (clang + cc1plus for libcrypto/libminui/twrp) | 4 | 1.5–2.5 GB | 6–10 GB |
| highmem link / `soong_zip` / `mkbootimg` / `imgdiff` | 2 | 6–8 GB | 12–16 GB |
| soong/kati/ninja + java-less TWRP front-end | 1 | ~1 GB | 1 GB |

Worst-case overlap ≈ 19–21 GB against 16 GB of RAM ⇒ **3–5 GB spills to swap**, which is exactly what the
8 GB swap file is for. That is also why the guide forbids `-j8`: 8 compile jobs alone reach 20 GB and turn
swap into a treadmill (`si/so` never returns to 0) — slower *and* likely to hit the 350 min cap.

Why `JOBS=4` and not the `6` of guide table row "16 GB + 16 GB swap": that row assumes ≥ 6 vCPU. Here `nproc`
is the binding constraint, so extra swap buys **headroom, not throughput** — hence 8 GB, not 16 GB (disk is the
scarcer resource, §5).

`JOBS` resolution lives in `build.sh` (not in YAML) so a self-hosted runner with 32 GB / 8 vCPU
automatically gets `JOBS=8`; `JOBS=<n>` or the `jobs` dispatch input overrides it.

Guards: `stage_build` exports `NINJA_HIGHMEM_NUM_JOBS`, starts a 30 s `mem-timeline.log`
(`MemAvailable`, `SwapUsed`, `Committed_AS`) and `stage_preflight` warns when `SwapTotal < 2 GB`.

---

## 4. Swap numbers and the `swap-storage: false` hard rule

Guide §0.5: `jlumbroso/free-disk-space`'s `swap-storage: true` **deletes the runner's swap**, and the job then
dies with no error mentioning the action. This draft therefore does the cleanup in **plain shell** and keeps a
*verifiable* invariant instead of trusting an action default:

```
swap_before=$(sudo swapon --show --noheadings | wc -l)
… cleanup …
swap_after=$(sudo swapon --show --noheadings | wc -l)
[ swap_before -gt 0 ] && [ swap_after -lt swap_before ]  →  ::error:: + exit 1
```

Then, *after* the files have been freed (never before — `fallocate` needs the space):

| parameter | value | reason |
|---|---|---|
| swap size | **8 GB** (`SWAP_GB`) | 1.5× RAM ⇒ absorbs a 3–6 GB overshoot; 16 GB would cost 8 GB of the disk budget for zero extra parallelism on 4 vCPU |
| adaptive downgrade | **4 GB** when `df /` < 45 GB after cleanup | protecting `out/` beats swap headroom when the disk is the limiter |
| `vm.swappiness` | 10 | swap is an emergency cushion, not a hot page store |
| `vm.vfs_cache_pressure` | 50 | keep dentry/inode cache under churn |
| `vm.overcommit_memory` | 1 | prevents early `malloc`/`posix_spawn` ENOMEM; the OOM killer still arbitrates |
| creation | `fallocate -l <n>G /swapfile` with `dd bs=1M` fallback | network block storage sometimes refuses fallocate |
| verification | `awk '/^SwapTotal:/{exit !($2>0)}'` | fail the job now, not 2 h later inside ninja |

Note the contradiction inside ref 17 itself: the §3/§4/§5 YAML samples still carry `swap-storage: true`
while §0.5 says it must be `false`. This draft follows §0.5 (and `assets/workflows/twrp-build.yml`, which
already says `false`) and additionally asserts it at runtime.

---

## 5. Disk budget: the real constraint (and the fail-fast design)

Runner as given: **4 vCPU / 16 GB RAM / ~14 GB free of ~65–70 GB total**.

| stage | delta | running free (typical) |
|---|---|---|
| runner as-is | — | 14 GB |
| shell cleanup (android SDK 8–10, hostedtoolcache 4–7, ghc/ghcup 5–7, dotnet 2.5–3, boost 1.5–2, swift 1.5, node_modules 0.3, docker prune 3–6, apt lists 0.3) | +27…+37 | **41–51 GB** |
| own swap (8 GB, or 4 GB when < 45 GB free) | −8 (−4) | **33–43 GB** |
| `repo sync` twrp-12.1 `--depth=1 -c` (work tree ~20–24 GB + `.repo` objects ~8–11 GB) | −28…−35 | **5–8 GB** |
| reclaim `.repo/project-objects` (only when free < 14 GB; nothing in the build path calls repo/git) | +8…+11 | **13–19 GB** |
| `mka bootimage` `out/` (ramdisk + soong intermediates; guide: out 25–55 GB for recovery builds, bootimage is the small end) | −15…−25 | **−6…+4 GB** |

Honest reading: **a single sync+build job on a ~70 GB root is at the edge of feasibility**, exactly as the
guide warns ("单作业跑 sync + 全量 build 非常紧"). The design therefore does not pretend otherwise:

1. **Fail fast, loudly, before the expensive part** — thresholds in `bf61.env`:
   `MIN_FREE_GB_BEFORE_SYNC=40`, `MIN_FREE_GB_AFTER_SYNC=14`, `MIN_FREE_GB_BEFORE_BUILD=12`.
   `stage_preflight` aborts with the exact cleanup remediation text and the `swap-storage: false` reminder;
   `stage_sync` aborts before `mka` if the budget is gone. `ALLOW_TIGHT_DISK=1` opts out deliberately.
2. **Adaptive swap** (§4) so a tight disk loses 4 GB, not 8.
3. **`.repo/project-objects` reclaim** (≈8–11 GB) triggered only when space is short, i.e. we never pay for it
   on a roomy self-hosted runner.
4. **Escape hatches, in order of preference** (each is a one-line change, documented here rather than hidden):
   - **self-hosted runner** (guide §5): ≥ 8 vCPU / 32 GB / 200 GB SSD, no swap, `JOBS=8`; source + ccache
     persist in `$HOME`, so re-builds are 10–30 min instead of 3 h. This is the correct answer for iteration.
   - **larger hosted runner** (`runs-on:` e.g. `ubuntu-22.04-8core`, paid) — bigger disk + 8 vCPU.
   - **two-job split** is *not* a real option here: the guide suggests sync → artifact → build, but a 20–28 GB
     source tarball does not fit GitHub artifact limits/practical transfer.
5. `out/` trimming (`rm -rf out/target/common/obj`) is only useful *after* a successful build (frees 5–15 GB
   before the artifact step); it cannot rescue an ENOSPC at link time, so it is not in the flow.

`ccache` is therefore **off by default** in the workflow (`ccache: false` input): a 5 GB cache restored right
after the cleanup competes with `out/` for the same bytes and only accelerates the make/kati fraction
(soong is unaffected). Enable it via `workflow_dispatch` on a self-hosted runner.

---

## 6. repo / git flags (and why each one)

| flag | where | why |
|---|---|---|
| `--depth=1` | `repo init` (probed via `repo init --help`) | halves the manifest checkout; guide §0 |
| `-c` | `repo sync` | current branch only (no other TWRP branches) |
| `--force-sync` | `repo sync` | survives an interrupted previous sync / dirty project ("Cannot remove project: uncommitted changes") |
| `--no-clone-bundle` | init + sync | no bundle round-trip on a hosted runner |
| `--no-tags` | `repo sync` | tags are pure overhead for a build |
| `--optimized-fetch` | `repo sync` (feature-probed) | ≈30 % less traffic on multi-project fetch; skipped automatically on old `repo` |
| `-j$JOBS` | `repo sync` | 4 network-bound project fetches on 4 vCPU |
| retry ×1 | script | transient `git`/HTTP failures are the most common sync fault; the second attempt logs and aborts |
| `git config --global user.*` | script | `repo`/`git` refuse without an identity on a fresh runner |
| comment-only local manifest | script | documents that the device tree is intentionally not a repo project (§2) |

`repo` is bootstrapped from `storage.googleapis.com` into `$WORK/bin` and appended to `$GITHUB_PATH` when the
binary is missing (guide §6 "repo: command not found").

---

## 7. Cache strategy

| cache | decision | detail |
|---|---|---|
| TWRP source tree | **not cached** | 20–28 GB > 10 GB/repo cache limit; artifact round-trip is slower than `repo sync -c --depth=1` |
| `out/` | **not cached** | path-absolute, toolchain-version sensitive, 15–25 GB |
| ccache | **optional, 5 GB cap** | `actions/cache/restore@v4` / `actions/cache/save@v4`, key `ccache-bf61-bootimage-<sha>-<run_id>`, `restore-keys: ccache-bf61-bootimage-`; `continue-on-error: true` on save (a re-run of the same commit must not fail at the last step); default **off** for disk reasons (§5) |
| ccache effectiveness | documented honestly | `CCACHE_EXEC` is required by `build/core/ccache.mk` and is exported, but the TWRP recovery body is compiled by soong, which ccache does not wrap ⇒ expect a modest win on the kati/make half only |
| artifacts | 14-day retention, `compression-level: 0` | `boot.img` is already compressed; `upload-artifact` v4 per-artifact limit is far above ~12 MB |

Token surface: `actions/checkout@v4`, `actions/upload-artifact@v4`, `actions/cache/{restore,save}@v4` only —
all first-party, all using the implicit `GITHUB_TOKEN`; `permissions: contents: read`;
`persist-credentials: false`; no secrets, no PAT, no third-party action (`free-disk-space` is replaced by shell).

---

## 8. Output verification (`stage verify`) — why it exists

"Build succeeded but the image is unusable" is the expensive failure mode (guide §7). `build.sh` parses the
image itself in ~220 lines of stdlib Python (no `unpack_bootimg` dependency):

| check | catches |
|---|---|
| `ANDROID!` magic, `header_version`, `page_size` vs `BoardConfig.mk` (adopted from the tree, env is fallback) | header drift, wrong `BOARD_BOOTIMG_HEADER_VERSION`/`BOARD_KERNEL_PAGESIZE` |
| `kernel_size == size(prebuilt/kernel)` and gzip magic | stale/other kernel packed, kernel not repacked, `Image.gz` vs raw mismatch |
| `dtb_size == size(prebuilt/dtb.img)` (header v2) + `0xd7b7ab1e` / `0xd00dfeed` magic | missing `--dtb` in `BOARD_MKBOOTIMG_ARGS` (a real risk on this MTK layout) |
| computed image size vs `BOARD_BOOTIMAGE_PARTITION_SIZE` (32 771 072… here 33 554 432) | **unflashable oversize image** (`> partition` = FAIL, `> 94 %` = WARN) — with the exact overflow bytes |
| file length vs header-derived length | truncated download/build |
| `cmdline` contains `bootopt=64S3,32N2,64N2` (value taken from `BoardConfig.mk`) | cmdline lost, device does not boot MTK bootopt path |
| ramdisk decompress (gzip/lz4/raw cpio) + cpio `newc` walk | corrupt/empty ramdisk |
| ramdisk must contain `system/bin/recovery` or `sbin/recovery`, `*etc/recovery.fstab`, `twres/` | build "succeeded" but TWRP cannot start / no theme / no fstab (this tree deliberately ships `recovery/root/etc/recovery.fstab`) |
| `/etc/twrp.flags` presence | reported as INFO — this device tree does not ship one yet |

Results land in `work/logs/bootimg-info.txt` (uploaded, and inlined into `$GITHUB_STEP_SUMMARY`).

---

## 9. Validation record (exact commands and results)

Run from `/root/android_device_famue_bf61` on 2026-11-13.

```console
$ python3 -c 'import yaml;d=yaml.safe_load(open("research/ci/build.yml"));print("steps:",len(d["jobs"]["build"]["steps"]))'
steps: 16                              # rc=0  (PyYAML 6.0.3; note YAML 1.1 parses `on:` as True — handled)
$ bash -n research/ci/build.sh          # rc=0
$ bash -n research/ci/bf61.env          # rc=0
$ LC_ALL=C.UTF-8 shellcheck -f gcc research/ci/build.sh
                                        # rc=0, ShellCheck 0.11.0, zero findings at default severity
$ python3 -m py_compile <embedded verify python>        # rc=0 (224 lines, extracted by /tmp/ci-validate.py)
```

Structural validator (`/tmp/ci-validate.py`, 71 assertions — every `run:` block extracted and passed through
`bash -n`, `uses:` pinned to a major tag and first-party only, `on`/`concurrency`/`timeout-minutes`/
`permissions` present, step-timeout sum ≤ job timeout, no `${{ }}` leakage inside `run:`, env-file keys
cross-checked against `build.sh`):

```console
$ python3 /tmp/ci-validate.py
PASS 71 checks
NOTE build.sh hardcoded defaults not present in bf61.env (intentional): ART, CCACHE_DIR, DEVICE_TREE_REV,
     DEVICE_TREE_SRC, LOG_DIR, PACKAGE_STRICT, SRC, STRICT_RAMDISK, WORK
                                        # rc=0
```

Functional matrix (`/tmp/run-tests.sh`) against a **byte-accurate boot header v2 fixture**: real
`BoardConfig.mk` from this tree, 11.2 MB gzip kernel, MTK DTBO-container dtb, gzip `newc` ramdisk with
`system/bin/recovery` + `system/etc/recovery.fstab` + `twres/`, fake `build/envsetup.sh` (`lunch`, `mka`):

```console
$ bash /tmp/run-tests.sh
================ result: 40 passed, 0 failed ================
```

(The two harnesses are throwaway `/tmp` scripts, not deliverables — the reproducible core is the four
one-liners above plus `bash -n`/`shellcheck` on any `run:` block. `paths-ignore` is `**.md` only, on purpose:
until this draft is promoted, the workflow's own script lives under `research/ci/`, so ignoring `research/**`
would mean "changed the build script, no rebuild".)

Covered: `verify` good / truncated / wrong-kernel / oversize (33.2 MB → WARN at 99 %, 36.2 MB → FAIL
"超出 2 662 400 B") / missing `twres` (strict FAIL, `STRICT_RAMDISK=0` → WARN) / missing fstab / wrong
page_size / wrong cmdline / missing `boot.img`; `tree` exact-SHA OK (tree-info recorded), SHA mismatch → 5,
`check-tree.sh` failing → 5, missing `check-tree.sh` → 5, `SKIP_CHECK_TREE=1` → 0, `cp -a` fallback when
rsync absent → 0, local mode fetching a real SHA from GitHub → 0; `preflight` OK / disk-budget → 3 (message
contains the `swap-storage 必须为 false` warning) / optional-tool notices; `build` fixture `mka` OK → 0 and
`FIXTURE_MKA_RC=1` → 6 **with** `oom-report.txt` classified; `package` OK (`sha256sum -c SHA256SUMS`
verifies, `boot.img` listed) / missing image with `PACKAGE_STRICT=1` → 8 / loose → 0; usage/no-args → 2,
`--help` → 0, unknown stage → 2, missing env file → 2.

---

## 10. Failure modes (ref 17 §6, all 12 rows) → mitigation actually implemented

| ref-17 symptom | this design |
|---|---|
| `No space left on device` during sync | full shell cleanup (incl. `/opt/hostedtoolcache`), `--depth=1`, `MIN_FREE_GB_BEFORE_SYNC=40` fail-fast |
| `No space left on device` at link | `MIN_FREE_GB_BEFORE_BUILD=12` gate, `.repo/project-objects` reclaim, `DISK_FULL` classification in `oom-report.txt`, escape hatches in §5 |
| job killed at 6 h | job `timeout-minutes: 350`, sync 90 / build 240 step caps, ccache off by default, `concurrency` cancel-in-progress |
| `posix_spawn: Cannot allocate memory` / silent kill | 8 GB swap + `vm.overcommit_memory=1` + `JOBS=4` + `NINJA_HIGHMEM_NUM_JOBS=2` + memory timeline |
| cleaning the disk makes OOM *more* likely | cleanup is shell, never touches swap, and asserts the swap table (hard error if it shrank) |
| `-j` too large | `JOBS = min(nproc, (RAM+swap)/4)` computed from `/proc/meminfo`, never `$(nproc)` blindly; `-j` overridable |
| `repo: command not found` | `ensure_repo`: curl into `$WORK/bin`, `PATH`, `$GITHUB_PATH` |
| `repo sync` stuck / timeout | `--force-sync --no-tags --optimized-fetch`, one retry, `tee sync.log` |
| `lunch: command not found` / `set -u` exit | `set +u` … `set -u` bracketing, rc-checked `. envsetup.sh`, `lunch`; then `TARGET_PRODUCT` equality check |
| `Cannot remove project: uncommitted changes` | `--force-sync` on every sync |
| artifact upload fails (>2 GB) | only `boot.img` + logs (~12 MB), `compression-level: 0`, retention 14 d |
| success but 0-byte / wrong image | `BUILD_TARGET=bootimage` (A/B recovery-as-boot, no `recoveryimage`), `verify` stage, `PACKAGE_STRICT=1` |

Extra modes this design adds guards for: builds the wrong commit (#1), no `tools/check-tree.sh` (hard fail,
`SKIP_CHECK_TREE=1` to bypass), `boot.img` larger than the 32 MiB partition, kernel/dtb not the ones from this
tree, ramdisk without recovery/fstab/theme, and ENOSPC/OOM misclassification.

---

## 11. Expected runtime (ubuntu-22.04, 4 vCPU, cold cache)

| step | minutes | note |
|---|---|---|
| checkout | < 1 | 23 MB of git objects |
| cleanup + swap | 3–4 | `fallocate` 8 GB ≈ 15 s, `dd` fallback ≈ 90 s |
| deps (apt) | 2–4 | ~60 packages |
| preflight | < 1 | |
| `repo init` + `sync` | 20–40 | ~30 GB over the runner's uplink, 4 parallel projects |
| tree + `check-tree.sh` | < 1 | rsync of ~35 MB |
| `mka bootimage` −j4 | 90–180 | first build, no ccache; guide: 2–4 h for a full recovery build |
| verify + package | < 1 | |
| **total** | **2–4 h** | job cap 350 min |

Re-builds on a self-hosted runner with warm `out/` + ccache: 10–30 min.

---

## 12. What must be mirrored into the final `.github/workflows/build.yml`

1. **One block only**: workflow `env:` → `CI_DIR: ci` and `ENV_FILE: devices/bf61.env`
   (and copy `research/ci/build.sh` → `ci/build.sh`, `research/ci/bf61.env` → `devices/bf61.env`).
   Everything else is path-agnostic because the steps call `bash "$CI_DIR/build.sh" "$ENV_FILE" <stage>`.
2. Keep the stage **order and separation**: `preflight → sync → tree → build → verify → package`
   (separate steps = per-stage timeouts and honest failure attribution in the UI).
3. Keep `DEVICE_TREE_SRC: ${{ github.workspace }}` and `DEVICE_TREE_REV: ${{ github.sha }}` — this is the fix
   for "clones the default branch".
4. Keep the swap-table assertion in the cleanup step (the machine-checked form of `swap-storage: false`).
5. Keep `PACKAGE_STRICT: ${{ job.status == 'success' && '1' || '0' }}` and `if: always()` on package,
   `Job summary`, `Upload artifacts`, and the OOM diagnostics step.
6. Keep `concurrency` (group per `github.ref`, `cancel-in-progress: true`), `timeout-minutes: 350`,
   `permissions: contents: read`, `persist-credentials: false`.
7. `tools/check-tree.sh` must exist at the device-tree repo root and exit non-zero on a broken tree —
   `build.sh` fails the job if it is missing (`SKIP_CHECK_TREE=1` is the documented escape).
8. `chmod +x ci/build.sh` is optional (steps invoke `bash <file>`), but keep the shebang and `set -euo pipefail`.

Open items for the Lead: (a) keep `pull_request` builds or drop them to save minutes; (b) if the tree gate
lands at a different path, set `CHECK_TREE_SCRIPT` in `bf61.env` instead of editing `build.sh`;
(c) `prebuilt/dtbo.img` is the full 8 MiB partition dump — `bootimage` does not consume it (reported as a
note, no build impact; `dtbo.img` target would need a trimmed image).
