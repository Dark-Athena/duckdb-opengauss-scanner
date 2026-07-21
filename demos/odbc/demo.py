# ODBC demo (通过 pyodbc 调 DuckDB ODBC 驱动)。
#
# 前置:
#   1) 安装 DuckDB ODBC 驱动(得到 libduckdb_odbc.so), 并在 odbcinst.ini 里注册, 例如:
#        [DuckDB Driver]
#        Driver = /opt/duckdb-odbc/libduckdb_odbc.so
#   2) pip install pyodbc
# 运行: python odbc/demo.py
#
# 纯命令行(isql)方式: 在 odbc.ini 里建 DSN 并把 allow_unsigned_extensions=true 写进去,
#   [OpenGauss]
#   Driver = DuckDB Driver
#   Database = :memory:
#   allow_unsigned_extensions = true
# 然后 `isql OpenGauss` 进去逐条执行 LOAD / ATTACH / SELECT。
import os
import pyodbc

ext = os.environ.get("OG_EXT", "./opengauss_scanner.duckdb_extension")
conn = os.environ.get(
    "OG_CONN", "host=127.0.0.1 port=5432 dbname=test user=root password=Passwd@123"
)

# 关键: allow_unsigned_extensions 直接写进连接串(建连即启动期)。
cs = "Driver=DuckDB Driver;Database=:memory:;allow_unsigned_extensions=true"
cx = pyodbc.connect(cs, autocommit=True)
cur = cx.cursor()

cur.execute(f"LOAD '{ext}'")
cur.execute(f"ATTACH '{conn}' AS og (TYPE opengauss)")

for row in cur.execute("SELECT * FROM og.public.t ORDER BY id"):
    print(row)
