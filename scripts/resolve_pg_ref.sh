#!/usr/bin/env bash
#
# resolve_pg_ref.sh — 输入 DuckDB 版本号, 输出 postgres_scanner(duckdb-postgres) 的完整 40 位 SHA
#
# 原理: DuckDB 主仓库在每个 release tag 里用 .github/config 冻结了各扩展的 GIT_TAG。
#       这是"duckdb 版本 -> postgres_scanner 源码 commit"的权威且不可变来源,
#       对已 EOL(分支/标签都没了)的版本(如 1.4.5)同样有效。
#
# 用法:
#   scripts/resolve_pg_ref.sh 1.5.4          # 或 v1.5.4
#   SHA=$(scripts/resolve_pg_ref.sh 1.4.5)   # stdout 只输出 SHA, 便于脚本取值
#
# 说明(重要):
#   - 输出的是 DuckDB 官方构建 postgres_scanner 所用的源码 commit(完整 SHA)。
#   - 该 commit 自带的嵌套 duckdb 子模块可能"滞后"(官方构建时用 set_duckdb_version
#     覆盖成目标版本), 脚本会在 stderr 附带打印它引用的嵌套 duckdb 版本以供核对。
#
set -euo pipefail

usage() { echo "usage: $(basename "$0") <duckdb-version, e.g. 1.5.4 or v1.5.4>" >&2; exit 2; }

V="${1:-}"; [ -n "$V" ] || usage
case "$V" in v*) : ;; *) V="v$V" ;; esac

# 定位 duckdb 克隆(默认用 duckdb-postgres 的嵌套 duckdb, 也可用 DUCKDB_DIR 覆盖)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DUCKDB_DIR="${DUCKDB_DIR:-$SCRIPT_DIR/../duckdb-postgres/duckdb}"
is_git_repo() { git -C "$1" rev-parse --git-dir >/dev/null 2>&1; }
is_git_repo "$DUCKDB_DIR" || { echo "error: 找不到 duckdb 克隆: $DUCKDB_DIR (可用 DUCKDB_DIR 指定)" >&2; exit 1; }

# 抓取该 tag(浅, 不动工作区)
if ! git -C "$DUCKDB_DIR" cat-file -e "${V}^{commit}" 2>/dev/null; then
  git -C "$DUCKDB_DIR" fetch --depth 1 origin "tag" "$V" >/dev/null 2>&1 \
    || { echo "error: 无法获取 duckdb tag $V (版本号是否正确?)" >&2; exit 1; }
fi

# 读取 postgres_scanner 的 pin: 优先新版拆分布局, 回退旧版内联布局
read_pin() {
  # 新布局(1.4.x/1.5.x+): .github/config/extensions/postgres_scanner.cmake
  if git -C "$DUCKDB_DIR" cat-file -e "${V}:.github/config/extensions/postgres_scanner.cmake" 2>/dev/null; then
    git -C "$DUCKDB_DIR" show "${V}:.github/config/extensions/postgres_scanner.cmake"
    return
  fi
  # 旧布局: 内联在 out_of_tree_extensions.cmake, 截取 postgres_scanner 那段
  git -C "$DUCKDB_DIR" show "${V}:.github/config/out_of_tree_extensions.cmake" \
    | awk '/duckdb_extension_load\(postgres_scanner/{f=1} f{print} f&&/\)/{exit}'
}

PIN_BLOCK="$(read_pin || true)"
[ -n "$PIN_BLOCK" ] || { echo "error: $V 的清单里找不到 postgres_scanner" >&2; exit 1; }

SHA="$(printf '%s\n' "$PIN_BLOCK" | grep -iE '(^|[[:space:]])GIT_TAG([[:space:]]|$)' | head -n1 | awk '{for(i=1;i<=NF;i++) if(tolower($i)=="git_tag"){print $(i+1); exit}}')"
[ -n "$SHA" ] || { echo "error: $V 的 postgres_scanner 段里没有 GIT_TAG" >&2; exit 1; }

# 附带信息 -> stderr(不污染 stdout)
{
  echo "duckdb 版本:        $V"
  echo "postgres_scanner:   $SHA"
  # 尝试展开成完整 SHA 并核对其嵌套 duckdb(需能取到该 commit)
  PG_DIR="$SCRIPT_DIR/../duckdb-postgres"
  if is_git_repo "$PG_DIR"; then
    if ! git -C "$PG_DIR" cat-file -e "${SHA}^{commit}" 2>/dev/null; then
      git -C "$PG_DIR" fetch --depth 1 origin "$SHA" >/dev/null 2>&1 || true
    fi
    if git -C "$PG_DIR" cat-file -e "${SHA}^{commit}" 2>/dev/null; then
      NESTED="$(git -C "$PG_DIR" ls-tree "$SHA" duckdb 2>/dev/null | awk '{print $3}')"
      if [ -n "$NESTED" ]; then
        if ! git -C "$DUCKDB_DIR" cat-file -e "${NESTED}^{commit}" 2>/dev/null; then
          git -C "$DUCKDB_DIR" fetch --depth 1 origin "$NESTED" >/dev/null 2>&1 || true
        fi
        DESC="$(git -C "$DUCKDB_DIR" describe --tags "$NESTED" 2>/dev/null || echo '未知')"
        echo "其内嵌 duckdb:      $NESTED ($DESC)"
        echo "(注: 官方构建会用 set_duckdb_version 把内嵌 duckdb 覆盖成 $V, 内嵌值滞后属正常)"
      fi
    else
      echo "(提示: 该 commit 可能在已删分支上, 无法本地展开/核对内嵌 duckdb)"
    fi
  fi
} >&2

# 主输出: 只打印 SHA
echo "$SHA"
