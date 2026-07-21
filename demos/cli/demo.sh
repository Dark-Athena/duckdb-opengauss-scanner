#!/usr/bin/env bash
# CLI demo: 用 -unsigned 在"启动时"开启允许未签名扩展, 再 LOAD + ATTACH + 查询。
#
# 运行: bash cli/demo.sh
#
# 想每次自动生效(不再手敲 -unsigned)?
#   1) ~/.bashrc:   alias duckdb='duckdb -unsigned'
#   2) ~/.duckdbrc: LOAD '/abs/path/to/opengauss_scanner.duckdb_extension';
set -euo pipefail

OG_EXT="${OG_EXT:-$PWD/opengauss_scanner.duckdb_extension}"
OG_CONN="${OG_CONN:-host=127.0.0.1 port=5432 dbname=test user=root password=Passwd@123}"

# -unsigned 只能在启动时给: allow_unsigned_extensions 是启动期设置, 连上后再 SET 会报错。
duckdb -unsigned -c "
  LOAD '${OG_EXT}';
  ATTACH '${OG_CONN}' AS og (TYPE opengauss);
  SELECT * FROM og.public.t ORDER BY id;
"
