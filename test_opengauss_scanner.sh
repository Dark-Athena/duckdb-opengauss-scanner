#!/usr/bin/env bash
# ============================================================================
# opengauss_scanner 功能测试脚本
# 验证扩展能否正常加载、连接 openGauss 家族数据库并读取数据。
#
# 用法:
#   ./test_opengauss_scanner.sh [选项]
# 选项(均有默认值, 可用环境变量或参数覆盖):
#   --duckdb   <path>   duckdb CLI 路径     (默认: 自动探测)
#   --ext      <path>   扩展 .duckdb_extension 路径 (默认: ./dist/opengauss_scanner.duckdb_extension)
#   --host     <host>   数据库地址          (默认: 192.168.163.140)
#   --port     <port>   端口                (默认: 8000)
#   --db       <name>   数据库名            (默认: postgres)
#   --user     <user>   用户                (默认: root)
#   --password <pw>     密码                (默认: Gaussdb@123)
# 示例:
#   ./test_opengauss_scanner.sh --host 127.0.0.1 --port 5432 --user gaussdb --password 'Xxx@123'
# ============================================================================
set -u

# ------------------------------- 默认参数 -----------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DUCKDB=""
EXT="${SCRIPT_DIR}/dist/opengauss_scanner.duckdb_extension"
DB_HOST="192.168.163.140"
DB_PORT="8000"
DB_NAME="postgres"
DB_USER="root"
DB_PASS="Gaussdb@123"

while [[ $# -gt 0 ]]; do
	case "$1" in
		--duckdb)   DUCKDB="$2"; shift 2 ;;
		--ext)      EXT="$2"; shift 2 ;;
		--host)     DB_HOST="$2"; shift 2 ;;
		--port)     DB_PORT="$2"; shift 2 ;;
		--db)       DB_NAME="$2"; shift 2 ;;
		--user)     DB_USER="$2"; shift 2 ;;
		--password) DB_PASS="$2"; shift 2 ;;
		-h|--help)  grep -E '^#( |$)' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
		*) echo "未知参数: $1"; exit 2 ;;
	esac
done

# 自动探测 duckdb CLI
if [[ -z "${DUCKDB}" ]]; then
	for c in "${SCRIPT_DIR}/duckdb-postgres/build/release/duckdb" "$(command -v duckdb 2>/dev/null || true)"; do
		[[ -n "${c}" && -x "${c}" ]] && { DUCKDB="${c}"; break; }
	done
fi

# ------------------------------- 输出辅助 -----------------------------------
GREEN='\033[0;32m'; RED='\033[0;31m'; YEL='\033[0;33m'; NC='\033[0m'
PASS=0; FAIL=0
ok()   { echo -e "  ${GREEN}[PASS]${NC} $1"; PASS=$((PASS+1)); }
bad()  { echo -e "  ${RED}[FAIL]${NC} $1"; FAIL=$((FAIL+1)); }
info() { echo -e "${YEL}== $1 ==${NC}"; }

CONNSTR="host=${DB_HOST} port=${DB_PORT} dbname=${DB_NAME} user=${DB_USER} password=${DB_PASS} connect_timeout=10"
# 每次 duckdb -c 是独立进程, 需重复加载与挂载前缀。
# 未签名扩展由 CLI 的 -unsigned 参数放行, 不能运行时 SET allow_unsigned_extensions。
PRELUDE="LOAD '${EXT}';
ATTACH '${CONNSTR}' AS og (TYPE postgres);"

# run_sql "<sql>"  ->  在 stdout 返回查询结果(含 PRELUDE)
run_sql() {
	"${DUCKDB}" -unsigned -noheader -list -c "${PRELUDE}
$1" 2>&1
}

# check "<描述>" "<sql>" "<期望输出中包含的子串>"
check() {
	local desc="$1" sql="$2" want="$3" out
	out="$(run_sql "${sql}")"
	if grep -qF "${want}" <<<"${out}"; then
		ok "${desc} => $(head -n1 <<<"${out}")"
	else
		bad "${desc}"
		echo "        期望包含: ${want}"
		echo "        实际输出: $(head -n3 <<<"${out}" | tr '\n' '|')"
	fi
}

# ------------------------------- 前置检查 -----------------------------------
info "0. 前置检查"
[[ -n "${DUCKDB}" && -x "${DUCKDB}" ]] && ok "duckdb CLI: ${DUCKDB}" || { bad "未找到可执行的 duckdb CLI (用 --duckdb 指定)"; exit 1; }
[[ -f "${EXT}" ]] && ok "扩展文件: ${EXT}" || { bad "未找到扩展文件: ${EXT} (用 --ext 指定)"; exit 1; }

info "1. 运行时依赖 (rpath + ldd)"
RPATH="$(readelf -d "${EXT}" 2>/dev/null | grep -E 'RPATH|RUNPATH' | sed -E 's/.*\[(.*)\].*/\1/')"
[[ -n "${RPATH}" ]] && ok "rpath = ${RPATH}" || bad "扩展未设置 rpath"
MISSING="$(ldd "${EXT}" 2>&1 | grep 'not found' || true)"
[[ -z "${MISSING}" ]] && ok "ldd: 所有依赖均可解析" || bad "ldd 存在缺失依赖:\n${MISSING}"

# ------------------------------- 功能检查 -----------------------------------
info "2. 加载与连接"
check "LOAD + ATTACH (sha256 认证)" "SELECT 'connected' AS s;" "connected"

info "3. 核心特性"
check "默认启用 TEXT 协议 (pg_use_text_protocol=true)" \
	"SELECT current_setting('pg_use_text_protocol');" "true"

info "4. openGauss 家族能力探测"
VER="$(run_sql "SELECT * FROM postgres_query('og','SELECT version()');" | tail -n1)"
[[ -n "${VER}" && ! "${VER}" =~ [Ee]rror ]] && ok "version() => ${VER}" || bad "无法获取 version(): ${VER}"
WVN="$(run_sql "SELECT * FROM postgres_query('og','SELECT working_version_num()');" | tail -n1)"
[[ "${WVN}" =~ ^[0-9]+$ ]] && ok "working_version_num() => ${WVN}" || bad "working_version_num() 非预期: ${WVN}"

info "5. 元数据与数据读取"
NTAB="$(run_sql "SELECT COUNT(*) FROM postgres_query('og','SELECT tablename FROM pg_tables');" | tail -n1)"
[[ "${NTAB}" =~ ^[0-9]+$ && "${NTAB}" -gt 0 ]] && ok "pg_tables 数量 => ${NTAB}" || bad "pg_tables 计数异常: ${NTAB}"

NSCH="$(run_sql "SELECT COUNT(*) FROM postgres_query('og','SELECT schema_name FROM information_schema.schemata');" | tail -n1)"
[[ "${NSCH}" =~ ^[0-9]+$ && "${NSCH}" -gt 0 ]] && ok "schema 数量 => ${NSCH}" || bad "schema 计数异常: ${NSCH}"

info "6. 原生扫描路径 (非 postgres_query 透传)"
# 直接对 catalog 表发起原生扫描, 验证 TEXT 协议下的行读取
NATIVE="$(run_sql "SELECT current_database() AS db, count(*) AS n FROM og.information_schema.tables;" | tail -n1)"
if [[ "${NATIVE}" =~ [0-9] ]]; then
	ok "原生扫描 og.information_schema.tables => ${NATIVE}"
else
	bad "原生扫描失败: ${NATIVE}"
fi

# ------------------------------- 汇总 ---------------------------------------
echo
info "测试汇总"
echo -e "  通过: ${GREEN}${PASS}${NC}   失败: ${RED}${FAIL}${NC}"
[[ ${FAIL} -eq 0 ]] && { echo -e "${GREEN}全部通过, 扩展可正常使用。${NC}"; exit 0; } \
	|| { echo -e "${RED}存在失败项, 请检查上面输出。${NC}"; exit 1; }
