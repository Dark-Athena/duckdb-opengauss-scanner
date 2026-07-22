#!/usr/bin/env bash
#
# select_duckdb.sh — 官方口径的 DuckDB 版本切换器(本地 & CI 共用)
#
# 做两件事(等价 DuckDB 官方发布流程):
#   1. 把 duckdb-postgres 切到 duckdb_versions.json 登记的 postgres_scanner 官方 pin;
#   2. 把其嵌套的 duckdb 子模块强制 checkout 到目标版本 tag —— 因为官方 pin 自带的
#      嵌套 duckdb 可能滞后, 这一步等价于官方 Makefile 的 `make set_duckdb_version`。
# 因此对分支已删的 EOL 版本(如 v1.4.5)同样可用。
#
# 用法:
#   scripts/select_duckdb.sh <duckdb-version>            # 从清单读 pin, 如 v1.5.4 / 1.4.5
#   scripts/select_duckdb.sh <duckdb-version> <pin-sha>  # 显式传 pin(CI 用, 免依赖 python)
#
# 幂等: 已处于目标状态时跳过所有网络操作。
#
set -euo pipefail

log() { printf '\033[1;36m[select-duckdb]\033[0m %s\n' "$*" >&2; }
die() { printf '\033[1;31m[select-duckdb][ERROR]\033[0m %s\n' "$*" >&2; exit 1; }

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PG_DIR="${DUCKDB_POSTGRES_DIR:-$ROOT/duckdb-postgres}"
DUCK_DIR="$PG_DIR/duckdb"

V="${1:-}"; [ -n "$V" ] || die "用法: $(basename "$0") <duckdb-version, 如 v1.5.4> [pin-sha]"
case "$V" in v*) : ;; *) V="v$V" ;; esac
PIN="${2:-}"

# 未显式传 pin 时, 从清单解析
if [ -z "$PIN" ]; then
  [ -f "$ROOT/duckdb_versions.json" ] || die "找不到 $ROOT/duckdb_versions.json"
  PIN="$(python3 - "$V" <<'PY'
import json, sys
v = sys.argv[1]
m = json.load(open("duckdb_versions.json"))
print(m["versions"].get(v, ""))
PY
)"
  [ -n "$PIN" ] || die "duckdb_versions.json 未登记 $V (可用 scripts/resolve_pg_ref.sh $V 解析 pin 后登记)"
fi

git -C "$PG_DIR" rev-parse --git-dir >/dev/null 2>&1 || die "$PG_DIR 不是 git 仓库"

# 1) duckdb-postgres → 官方 pin
if [ "$(git -C "$PG_DIR" rev-parse HEAD 2>/dev/null || true)" != "$PIN" ]; then
  log "duckdb-postgres → $PIN"
  git -C "$PG_DIR" cat-file -e "${PIN}^{commit}" 2>/dev/null || git -C "$PG_DIR" fetch --depth 1 origin "$PIN"
  git -C "$PG_DIR" checkout -f --detach "$PIN"
  git -C "$PG_DIR" submodule sync --recursive
  git -C "$PG_DIR" submodule update --init --recursive --depth 1
else
  log "duckdb-postgres 已在 $PIN, 跳过"
fi

# 2) 嵌套 duckdb → 目标版本 tag(覆盖可能滞后的 pin, 等价 set_duckdb_version)
git -C "$DUCK_DIR" rev-parse --git-dir >/dev/null 2>&1 || die "$DUCK_DIR 未初始化(嵌套 duckdb 子模块缺失)"
if [ "$(git -C "$DUCK_DIR" describe --tags 2>/dev/null || true)" != "$V" ]; then
  log "内嵌 duckdb → $V (覆盖 pin 自带的滞后版本)"
  git -C "$DUCK_DIR" cat-file -e "${V}^{commit}" 2>/dev/null || git -C "$DUCK_DIR" fetch --depth 1 origin tag "$V"
  git -C "$DUCK_DIR" checkout -f "$V"
else
  log "内嵌 duckdb 已在 $V, 跳过"
fi

log "完成: duckdb-postgres@$(git -C "$PG_DIR" rev-parse --short HEAD), 内嵌 duckdb@$(git -C "$DUCK_DIR" describe --tags 2>/dev/null || git -C "$DUCK_DIR" rev-parse --short HEAD)"
