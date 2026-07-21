#!/usr/bin/env python3
# Python demo: pip install duckdb
# 运行: python python/demo.py
import os
import duckdb

ext = os.environ.get("OG_EXT", "./opengauss_scanner.duckdb_extension")
conn = os.environ.get(
    "OG_CONN", "host=127.0.0.1 port=5432 dbname=test user=root password=Passwd@123"
)

# 关键: 在 connect 时通过 config 开启; 连上后再 SET 会报错(启动期设置)。
con = duckdb.connect(config={"allow_unsigned_extensions": "true"})

con.execute(f"LOAD '{ext}'")
con.execute(f"ATTACH '{conn}' AS og (TYPE opengauss)")

for row in con.execute("SELECT * FROM og.public.t ORDER BY id").fetchall():
    print(row)
