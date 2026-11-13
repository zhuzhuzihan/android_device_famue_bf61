# 由 build/envsetup.sh 在 lunch 前 source。
# minimal manifest 缺不少仓库，不打开这个开关 lunch 阶段就会失败。
# 注意：这里不要用 set -u / set -e —— envsetup 会被直接打断。
export ALLOW_MISSING_DEPENDENCIES=true
