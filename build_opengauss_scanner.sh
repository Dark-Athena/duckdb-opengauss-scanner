#!/usr/bin/env bash
#
# build_opengauss_scanner.sh
#
# 基于 duckdb-postgres(postgres_scanner) 构建面向 openGauss 家族
# (openGauss / MogDB / VastBase / PanWeiDB / GaussDB) 的 DuckDB 扩展。
#
# 设计原则：
#   1. 不修改 duckdb-postgres 仓库中已提交的源码。构建前对少量文件打补丁，
#      构建结束(含失败/中断)后通过 trap 自动还原，保证 git 工作区干净。
#   2. 链接指定目录下 openGauss 已编译好的 libpq(.so)，无需 openGauss 源码。
#   3. 扩展改名为 opengauss_scanner，默认走 TEXT 协议(免手动 SET)。
#   4. 运行期通过扩展自身的 DT_RPATH=$ORIGIN 从同目录 bundle 解析 libpq
#      及其 openGauss 专属 krb5/gss/crypto 依赖，与启动 DuckDB 的宿主语言
#      (Java / C / Python / CLI) 及当前工作目录无关。
#
# 用法:
#   ./build_opengauss_scanner.sh [--libpq-dir DIR] [--duckdb-postgres DIR]
#                                [--output DIR] [--jobs N] [--debug] [--ninja]
#
set -euo pipefail

# ----------------------------------------------------------------------------
# 默认参数
# ----------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIBPQ_DIR="${SCRIPT_DIR}/libpq"
PG_SRC_DIR="${SCRIPT_DIR}/duckdb-postgres"
OUTPUT_DIR="${SCRIPT_DIR}/dist"
EXT_OLD_NAME="postgres_scanner"
EXT_NEW_NAME="opengauss_scanner"
JOBS="$(nproc 2>/dev/null || echo 4)"
BUILD_TYPE="release"
GEN_NINJA=0

log()  { printf '\033[1;32m[og-build]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[og-build][WARN]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[og-build][ERROR]\033[0m %s\n' "$*" >&2; exit 1; }

usage() {
	sed -n '2,40p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
	exit 0
}

# ----------------------------------------------------------------------------
# 解析参数
# ----------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
	case "$1" in
		--libpq-dir)        LIBPQ_DIR="$(cd "$2" && pwd)"; shift 2 ;;
		--duckdb-postgres)  PG_SRC_DIR="$(cd "$2" && pwd)"; shift 2 ;;
		--output)           OUTPUT_DIR="$2"; shift 2 ;;
		--jobs|-j)          JOBS="$2"; shift 2 ;;
		--debug)            BUILD_TYPE="debug"; shift ;;
		--ninja)            GEN_NINJA=1; shift ;;
		-h|--help)          usage ;;
		*) die "未知参数: $1 (用 --help 查看用法)" ;;
	esac
done

# 输出目录转绝对路径
mkdir -p "${OUTPUT_DIR}"
OUTPUT_DIR="$(cd "${OUTPUT_DIR}" && pwd)"

LIBPQ_INC="${LIBPQ_DIR}/include"
LIBPQ_LIB="${LIBPQ_DIR}/lib"

# ----------------------------------------------------------------------------
# 前置校验
# ----------------------------------------------------------------------------
log "libpq 目录     : ${LIBPQ_DIR}"
log "扩展源码目录   : ${PG_SRC_DIR}"
log "输出目录       : ${OUTPUT_DIR}"
log "构建类型/并发  : ${BUILD_TYPE} / -j${JOBS}"

[[ -f "${LIBPQ_INC}/libpq-fe.h" ]] || die "找不到 ${LIBPQ_INC}/libpq-fe.h，请用 --libpq-dir 指定正确的 openGauss libpq 目录"
# 定位实际链接目标(优先 libpq.so，退化到具体版本文件)
if   [[ -e "${LIBPQ_LIB}/libpq.so"     ]]; then LIBPQ_LINK="${LIBPQ_LIB}/libpq.so"
elif [[ -e "${LIBPQ_LIB}/libpq.so.5"   ]]; then LIBPQ_LINK="${LIBPQ_LIB}/libpq.so.5"
else LIBPQ_LINK="$(ls "${LIBPQ_LIB}"/libpq.so.5.* 2>/dev/null | head -n1 || true)"; fi
[[ -n "${LIBPQ_LINK}" && -e "${LIBPQ_LINK}" ]] || die "在 ${LIBPQ_LIB} 下找不到 libpq.so*"
log "链接目标       : ${LIBPQ_LINK}"

[[ -d "${PG_SRC_DIR}/duckdb" && -f "${PG_SRC_DIR}/duckdb/Makefile" ]] || \
	die "duckdb 子模块未拉取，请先在 ${PG_SRC_DIR} 执行: git submodule update --init --recursive"

command -v cmake >/dev/null || die "缺少 cmake"
command -v make  >/dev/null || die "缺少 make"
if [[ ${GEN_NINJA} -eq 1 ]]; then command -v ninja >/dev/null || die "指定了 --ninja 但未安装 ninja"; fi

# ----------------------------------------------------------------------------
# 打补丁 / 自动还原 (trap)
# ----------------------------------------------------------------------------
declare -a BACKED_UP=()

restore_sources() {
	local f
	for f in "${BACKED_UP[@]:-}"; do
		[[ -n "${f}" && -f "${f}.ogbak" ]] || continue
		mv -f "${f}.ogbak" "${f}"
	done
	if [[ ${#BACKED_UP[@]} -gt 0 ]]; then
		log "已还原被临时修改的源码文件 (git 工作区保持干净)"
	fi
}
trap restore_sources EXIT INT TERM

edit_begin() {  # $1 = file (相对 PG_SRC_DIR)
	local f="${PG_SRC_DIR}/$1"
	[[ -f "${f}" ]] || die "待修改文件不存在: ${f}"
	cp -p "${f}" "${f}.ogbak"
	BACKED_UP+=("${f}")
}

log "== 阶段1: 对源码打临时补丁 =="

# (a) 改名: Makefile EXT_NAME
edit_begin "Makefile"
sed -i "s/^EXT_NAME=${EXT_OLD_NAME}\b/EXT_NAME=${EXT_NEW_NAME}/" "${PG_SRC_DIR}/Makefile"

# (b) 改名: extension_config.cmake 的 load 名
edit_begin "extension_config.cmake"
sed -i "s/duckdb_extension_load(${EXT_OLD_NAME}\b/duckdb_extension_load(${EXT_NEW_NAME}/" \
	"${PG_SRC_DIR}/extension_config.cmake"

# (c) 改名 + libpq 重定向 + rpath: CMakeLists.txt
edit_begin "CMakeLists.txt"
CM="${PG_SRC_DIR}/CMakeLists.txt"
# TARGET_NAME
sed -i "s/set(TARGET_NAME ${EXT_OLD_NAME})/set(TARGET_NAME ${EXT_NEW_NAME})/" "${CM}"
# 绕过 find_package(PostgreSQL)，改用指向 openGauss libpq 的 IMPORTED target。
# 保持后续 \${PostgreSQL_INCLUDE_DIRS} 与 PostgreSQL::PostgreSQL 的用法不变。
python3 - "${CM}" "${LIBPQ_INC}" "${LIBPQ_LINK}" <<'PYEOF'
import sys, io
cm, inc, link = sys.argv[1], sys.argv[2], sys.argv[3]
with io.open(cm, encoding="utf-8") as f:
    s = f.read()

# 1) 替换 find_package(PostgreSQL REQUIRED) 为 openGauss libpq 的 IMPORTED target
old = "find_package(PostgreSQL REQUIRED)"
new = (
    "# [opengauss_scanner] 使用外部 openGauss libpq，绕过 find_package(PostgreSQL)\n"
    "set(PostgreSQL_INCLUDE_DIRS \"{inc}\")\n"
    "set(PostgreSQL_LIBRARIES \"{link}\")\n"
    "if(NOT TARGET PostgreSQL::PostgreSQL)\n"
    "  add_library(PostgreSQL::PostgreSQL SHARED IMPORTED)\n"
    "  set_target_properties(PostgreSQL::PostgreSQL PROPERTIES\n"
    "    IMPORTED_LOCATION \"{link}\"\n"
    "    INTERFACE_INCLUDE_DIRECTORIES \"{inc}\")\n"
    "endif()"
).format(inc=inc, link=link)
assert old in s, "CMakeLists.txt 中未找到 find_package(PostgreSQL REQUIRED)"
s = s.replace(old, new, 1)

# 2a) 强制老式 DT_RPATH(--disable-new-dtags)，使 rpath 可传递到 libpq 的
#     krb5/gss 二级依赖(DT_RUNPATH 不具备传递性)。
anchor = '"-Wl,-Bsymbolic"'
assert anchor in s, "CMakeLists.txt 中未找到 -Wl,-Bsymbolic 锚点"
s = s.replace(
    anchor,
    '"-Wl,-Bsymbolic"\n        "-Wl,--disable-new-dtags"',
    1,
)

# 2b) rpath=$ORIGIN 通过 CMake 目标属性设置(而非裸链接 flag)，由 CMake 负责
#     对生成器正确转义 $，避免 make/ninja 把 $ORIGIN 吃成 $。
#     BUILD_WITH_INSTALL_RPATH=ON 让构建期直接采用 $ORIGIN，并抑制 CMake
#     自动追加的 libpq 绝对路径 —— 产物只保留可移植的 $ORIGIN。
marker = "build_loadable_extension(${TARGET_NAME} ${PARAMETERS} ${ALL_OBJECT_FILES})"
assert marker in s, "CMakeLists.txt 中未找到 build_loadable_extension 调用"
s = s.replace(
    marker,
    marker + "\n\n"
    "# [opengauss_scanner] 便携 rpath: 扩展从同目录 lib/ 子目录解析 libpq 及其依赖\n"
    "if(NOT WIN32 AND NOT APPLE)\n"
    "  set_target_properties(${LOADABLE_EXTENSION_NAME} PROPERTIES\n"
    "    BUILD_RPATH \"$ORIGIN/lib\"\n"
    "    INSTALL_RPATH \"$ORIGIN/lib\"\n"
    "    BUILD_WITH_INSTALL_RPATH ON)\n"
    "endif()",
    1,
)

with io.open(cm, "w", encoding="utf-8") as f:
    f.write(s)
print("[patch] CMakeLists.txt 已重定向 libpq 并注入 rpath=$ORIGIN(DT_RPATH)")
PYEOF

# (d) 默认 TEXT 协议 + 入口重命名: postgres_extension.cpp
#     - pg_use_text_protocol 默认 false->true
#     - 扩展入口宏 DUCKDB_CPP_EXTENSION_ENTRY(postgres_scanner,..) 改名，
#       使生成的入口符号变为 <新名>_duckdb_cpp_init，与改名后的扩展文件匹配。
edit_begin "src/postgres_extension.cpp"
python3 - "${PG_SRC_DIR}/src/postgres_extension.cpp" "${EXT_OLD_NAME}" "${EXT_NEW_NAME}" <<'PYEOF'
import sys, io, re
p, old, new = sys.argv[1], sys.argv[2], sys.argv[3]
with io.open(p, encoding="utf-8") as f:
    s = f.read()
# 只改 pg_use_text_protocol 这一处的默认值，避免误伤其它 Value::BOOLEAN(false)
pat = re.compile(r'("pg_use_text_protocol".*?LogicalType::BOOLEAN,\s*)Value::BOOLEAN\(false\)', re.S)
s, n = pat.subn(r'\1Value::BOOLEAN(true)', s, count=1)
assert n == 1, "未能定位 pg_use_text_protocol 的默认值(false)"
# 重命名 C++ 扩展入口(生成 <new>_duckdb_cpp_init)，与改名后的扩展文件匹配
entry_old = "DUCKDB_CPP_EXTENSION_ENTRY({},".format(old)
entry_new = "DUCKDB_CPP_EXTENSION_ENTRY({},".format(new)
assert entry_old in s, "未找到扩展入口宏 " + entry_old
s = s.replace(entry_old, entry_new, 1)
with io.open(p, "w", encoding="utf-8") as f:
    f.write(s)
print("[patch] pg_use_text_protocol 默认 false->true; 入口宏 {} -> {}".format(old, new))
PYEOF

# (d2) OAuth 桩: openGauss libpq(基于 PG9.2)无新版 OAuth API(PQsetAuthDataHook 等)，
#       postgres_oauth.cpp 无法编译。用 no-op 桩替换(openGauss 家族不使用 OAuth)，
#       保留被其它文件引用的两个导出函数，调用点无需改动。
edit_begin "src/postgres_oauth.cpp"
cat > "${PG_SRC_DIR}/src/postgres_oauth.cpp" <<'CPPEOF'
// [opengauss_scanner] OAuth 在 openGauss 家族不适用，替换为 no-op 桩，
// 以兼容不含新版 OAuth API 的 openGauss libpq。
#include "postgres_oauth.hpp"

namespace duckdb {

OAuthTokenHolder::~OAuthTokenHolder() {
}

void PostgresInitOAuthHook() {
}

OAuthTokenHolder SetThreadLocalOAuthTokenFromSessionOption(ClientContext &) {
	return OAuthTokenHolder();
}

} // namespace duckdb
CPPEOF
echo "[patch] postgres_oauth.cpp 已替换为 no-op 桩(兼容 openGauss libpq)"

# (d3) GCC11 兼容: postgres_scanner 主分支写法 `return func_ref;`（派生类
#      unique_ptr<TableFunctionRef> 隐式转基类 unique_ptr<TableRef>）在
#      C++17 + GCC11 下因“具名局部返回值隐式移动 + 继承构造 + 派生转基类推导”
#      被拒(其 CI 用 clang/更高版 gcc)。改为显式 std::move，语义等价、
#      对上游 rebase 影响极小。
edit_begin "src/storage/postgres_catalog.cpp"
python3 - "${PG_SRC_DIR}/src/storage/postgres_catalog.cpp" <<'PYEOF'
import sys, io
p = sys.argv[1]
with io.open(p, encoding="utf-8") as f:
    s = f.read()
old = "\tauto func_ref = make_uniq<TableFunctionRef>();\n" \
      "\tfunc_ref->function = make_uniq<FunctionExpression>(\"postgres_query\", std::move(args));\n" \
      "\treturn func_ref;\n"
new = "\tauto func_ref = make_uniq<TableFunctionRef>();\n" \
      "\tfunc_ref->function = make_uniq<FunctionExpression>(\"postgres_query\", std::move(args));\n" \
      "\treturn std::move(func_ref);\n"
assert old in s, "postgres_catalog.cpp 中未找到预期的 RemoteExecute 返回片段"
s = s.replace(old, new, 1)
with io.open(p, "w", encoding="utf-8") as f:
    f.write(s)
print("[patch] postgres_catalog.cpp: return func_ref -> return std::move(func_ref) (GCC11 兼容)")
PYEOF

# (d4) GCC11 兼容: postgres_secret_storage.cpp `return secret;`
#      (unique_ptr<BaseSecret> 隐式转 unique_ptr<const BaseSecret>，非常量→常量)
#      同属具名局部返回值隐式移动限制，改为显式 std::move。
edit_begin "src/storage/postgres_secret_storage.cpp"
python3 - "${PG_SRC_DIR}/src/storage/postgres_secret_storage.cpp" <<'PYEOF'
import sys, io
p = sys.argv[1]
with io.open(p, encoding="utf-8") as f:
    s = f.read()
old = "\tdeserializer.End();\n\n\treturn secret;\n"
new = "\tdeserializer.End();\n\n\treturn std::move(secret);\n"
assert old in s, "postgres_secret_storage.cpp 中未找到预期的 DeserializeSecret 返回片段"
s = s.replace(old, new, 1)
with io.open(p, "w", encoding="utf-8") as f:
    f.write(s)
print("[patch] postgres_secret_storage.cpp: return secret -> return std::move(secret) (GCC11 兼容)")
PYEOF

# (e) vcpkg.json 移除 libpq，避免误拉标准 libpq(本构建不使用 vcpkg)
if [[ -f "${PG_SRC_DIR}/vcpkg.json" ]]; then
	edit_begin "vcpkg.json"
	python3 - "${PG_SRC_DIR}/vcpkg.json" <<'PYEOF'
import sys, io, json
p = sys.argv[1]
with io.open(p, encoding="utf-8") as f:
    data = json.load(f)
deps = data.get("dependencies", [])
data["dependencies"] = [d for d in deps if (d if isinstance(d, str) else d.get("name")) != "libpq"]
with io.open(p, "w", encoding="utf-8") as f:
    json.dump(data, f, indent=2)
print("[patch] vcpkg.json 已移除 libpq 依赖")
PYEOF
fi

# ----------------------------------------------------------------------------
# 构建
# ----------------------------------------------------------------------------
log "== 阶段2: 构建扩展 (不启用 vcpkg，链接 openGauss libpq) =="

# 显式清空 vcpkg toolchain，确保 find_package(OpenSSL) 走系统库、libpq 走我们的补丁
export VCPKG_TOOLCHAIN_PATH=""
EXT_FLAGS="-DCMAKE_BUILD_RPATH_USE_ORIGIN=ON"
GEN_FLAG=""
[[ ${GEN_NINJA} -eq 1 ]] && GEN_FLAG="GEN=ninja"

set +e
( cd "${PG_SRC_DIR}" && \
  make "${BUILD_TYPE}" ${GEN_FLAG} EXT_FLAGS="${EXT_FLAGS}" -j"${JOBS}" )
BUILD_RC=$?
set -e
if [[ ${BUILD_RC} -ne 0 ]]; then
	# 失败时用 ninja keep-going 一次性枚举所有编译错误，便于定位而非逐个复现
	if [[ ${GEN_NINJA} -eq 1 && -f "${PG_SRC_DIR}/build/${BUILD_TYPE}/build.ninja" ]]; then
		warn "构建失败，正在用 ninja -k 0 枚举全部编译错误 ..."
		( cd "${PG_SRC_DIR}/build/${BUILD_TYPE}" && ninja -k 0 ) 2>&1 | grep -E "error:|could not convert" || true
	fi
	die "构建失败(rc=${BUILD_RC})。常见原因: 缺少 OpenSSL 开发头文件(libssl-dev) 或 duckdb 子模块未初始化"
fi

# ----------------------------------------------------------------------------
# 定位产物 + 打包 bundle
# ----------------------------------------------------------------------------
log "== 阶段3: 收集产物与运行时 bundle =="

EXT_FILE="$(find "${PG_SRC_DIR}/build/${BUILD_TYPE}" -name "${EXT_NEW_NAME}.duckdb_extension" 2>/dev/null | head -n1 || true)"
[[ -n "${EXT_FILE}" && -f "${EXT_FILE}" ]] || die "未找到构建产物 ${EXT_NEW_NAME}.duckdb_extension"
log "扩展产物: ${EXT_FILE}"

cp -f "${EXT_FILE}" "${OUTPUT_DIR}/"

# 运行时依赖放到 lib/ 子目录(保留原 libpq/lib 的目录结构与软链)。
# 扩展 rpath=$ORIGIN/lib，会从这里解析 libpq 及其 krb5/gss/crypto 依赖。
#
# 关键: 不写死库名(openGauss 用 *_gauss 后缀, GaussDB 用标准名 libkrb5.so 等)，
# 而是从 libpq 的“实际依赖闭包”自动收集——递归读取 NEEDED，只在 libpq 目录内
# 解析并拷贝，命中系统基础库(libc/libm/libstdc++ 等)则跳过(由宿主提供)。
BUNDLE_LIB_DIR="${OUTPUT_DIR}/lib"
mkdir -p "${BUNDLE_LIB_DIR}"

# 系统基础库: 不打包，交给宿主系统提供
is_system_lib() {
	case "$1" in
		libc.so*|libm.so*|libdl.so*|libpthread.so*|librt.so*|libgcc_s.so*|\
		ld-linux*|libstdc++.so*|libutil.so*|libnsl.so*|libresolv.so*|libanl.so*)
			return 0 ;;
	esac
	return 1
}

# 拷贝某 soname 对应的实体 + 同名的所有版本符号链接(libX.so / libX.so.N / libX.so.N.M)
copy_soname_family() {  # $1 = soname (如 libkrb5.so.3)
	local stem="${1%%.so*}" f     # libkrb5
	shopt -s nullglob
	for f in "${LIBPQ_LIB}/${stem}.so"*; do cp -a "${f}" "${BUNDLE_LIB_DIR}/"; done
	shopt -u nullglob
}

declare -A BUNDLED=()
declare -a QUEUE=()
# BFS 收集依赖闭包(迭代式, 用队列; 仅在 LIBPQ_LIB 内解析)。
# 用迭代而非递归, 避免“递归函数内嵌套进程替换 < <(readelf)”导致的 NEEDED 漏读。
QUEUE+=("$(basename "$(readlink -f "${LIBPQ_LINK}")")")
[[ -e "${LIBPQ_LIB}/libpq.so.5" ]] && QUEUE+=("libpq.so.5")

while [[ ${#QUEUE[@]} -gt 0 ]]; do
	soname="${QUEUE[0]}"; QUEUE=("${QUEUE[@]:1}")
	[[ -n "${BUNDLED[$soname]:-}" ]] && continue
	is_system_lib "${soname}" && continue
	file="${LIBPQ_LIB}/${soname}"
	[[ -e "${file}" ]] || continue         # 不在 libpq 目录 => 系统库, 跳过
	BUNDLED[$soname]=1
	copy_soname_family "${soname}"
	needs="$(readelf -d "${file}" 2>/dev/null | awk -F'[][]' '/NEEDED/{print $2}')"
	while IFS= read -r need; do
		[[ -n "${need}" ]] && QUEUE+=("${need}")
	done <<< "${needs}"
done

# 额外可选依赖(部分特性可能 dlopen 而不体现在 NEEDED, 存在才拷, 缺失无害)
for extra in libssl libcrypto libcjson libconfig libpgport_tool; do
	shopt -s nullglob
	for f in "${LIBPQ_LIB}/${extra}.so"*; do cp -a "${f}" "${BUNDLE_LIB_DIR}/"; done
	shopt -u nullglob
done

log "已打包依赖闭包(${#BUNDLED[@]} 个 soname): $(printf '%s ' "${!BUNDLED[@]}")"

# 生成使用说明
cat > "${OUTPUT_DIR}/USAGE.md" <<EOF
# opengauss_scanner 使用说明

本目录结构:
  opengauss_scanner.duckdb_extension   扩展本体
  lib/                                 运行时依赖(libpq 及其依赖闭包: krb5/gss/crypto 等)

扩展已内置 DT_RPATH=\$ORIGIN/lib，会自动从**本目录下的 lib/** 加载依赖，与启动
DuckDB 的语言(Java/C/Python/CLI)及当前工作目录无关。请将扩展与 lib/ 作为整体移动，
不要拆散(扩展与 lib/ 的相对位置必须保持)。

## 加载(未签名扩展)
\`\`\`sql
SET allow_unsigned_extensions=true;
LOAD '${OUTPUT_DIR}/${EXT_NEW_NAME}.duckdb_extension';
\`\`\`

## 连接 openGauss 家族数据库
默认已启用 TEXT 协议(pg_use_text_protocol=true)，无需手动 SET；
认证由 openGauss libpq 原生支持 sha256，无需将服务端改为 md5。
\`\`\`sql
ATTACH 'host=127.0.0.1 port=5432 dbname=postgres user=xxx password=xxx' AS og (TYPE postgres);
SELECT * FROM og.public.your_table LIMIT 10;
\`\`\`
EOF

log "== 完成 =="
log "产物目录: ${OUTPUT_DIR}"
ls -1 "${OUTPUT_DIR}"
log "验证扩展 rpath:"
readelf -d "${OUTPUT_DIR}/${EXT_NEW_NAME}.duckdb_extension" 2>/dev/null | grep -E "RPATH|RUNPATH|NEEDED.*pq" || true
