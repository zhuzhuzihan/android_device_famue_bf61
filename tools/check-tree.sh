#!/usr/bin/env bash
# 兼容入口：CI 与本地都可用 `bash tools/check-tree.sh [tree-root]`
set -euo pipefail
exec python3 "$(cd "$(dirname "$0")" && pwd)/check-tree.py" "$@"
