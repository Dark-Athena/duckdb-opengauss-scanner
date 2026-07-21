/*
 * C demo (DuckDB C API)。
 *
 * 编译(把 DUCKDB_INC/DUCKDB_LIB 换成你的 duckdb.h 与 libduckdb 所在目录):
 *   gcc c/demo.c -o /tmp/og_c_demo -I"$DUCKDB_INC" -L"$DUCKDB_LIB" -lduckdb
 * 运行:
 *   LD_LIBRARY_PATH="$DUCKDB_LIB" \
 *   OG_EXT=/abs/opengauss_scanner.duckdb_extension \
 *   OG_CONN="host=127.0.0.1 port=5432 dbname=test user=root password=Passwd@123" \
 *   /tmp/og_c_demo
 */
#include <stdio.h>
#include <stdlib.h>
#include "duckdb.h"

static void must(duckdb_connection con, const char *sql) {
	duckdb_result r;
	if (duckdb_query(con, sql, &r) == DuckDBError) {
		fprintf(stderr, "query failed: %s\n", duckdb_result_error(&r));
		duckdb_destroy_result(&r);
		exit(1);
	}
	duckdb_destroy_result(&r);
}

int main(void) {
	const char *ext = getenv("OG_EXT") ? getenv("OG_EXT") : "./opengauss_scanner.duckdb_extension";
	const char *conn = getenv("OG_CONN") ? getenv("OG_CONN")
	                                     : "host=127.0.0.1 port=5432 dbname=test user=root password=Passwd@123";

	/* 关键: 建库前在 config 里开启允许未签名扩展 */
	duckdb_config config;
	duckdb_create_config(&config);
	duckdb_set_config(config, "allow_unsigned_extensions", "true");

	duckdb_database db;
	char *err = NULL;
	if (duckdb_open_ext(NULL, &db, config, &err) == DuckDBError) {
		fprintf(stderr, "open failed: %s\n", err ? err : "(null)");
		duckdb_free(err);
		duckdb_destroy_config(&config);
		return 1;
	}
	duckdb_destroy_config(&config);

	duckdb_connection con;
	duckdb_connect(db, &con);

	char sql[1024];
	snprintf(sql, sizeof sql, "LOAD '%s'", ext);
	must(con, sql);
	snprintf(sql, sizeof sql, "ATTACH '%s' AS og (TYPE opengauss)", conn);
	must(con, sql);

	duckdb_result r;
	if (duckdb_query(con, "SELECT * FROM og.public.t ORDER BY id", &r) == DuckDBError) {
		fprintf(stderr, "select failed: %s\n", duckdb_result_error(&r));
		duckdb_destroy_result(&r);
		return 1;
	}
	idx_t rows = duckdb_row_count(&r);
	idx_t cols = duckdb_column_count(&r);
	for (idx_t i = 0; i < rows; i++) {
		for (idx_t j = 0; j < cols; j++) {
			char *v = duckdb_value_varchar(&r, j, i);
			printf("%s\t", v ? v : "NULL");
			duckdb_free(v);
		}
		printf("\n");
	}
	duckdb_destroy_result(&r);

	duckdb_disconnect(&con);
	duckdb_close(&db);
	return 0;
}
