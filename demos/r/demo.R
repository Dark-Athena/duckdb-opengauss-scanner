# R demo: install.packages("duckdb")
# 运行: Rscript r/demo.R
library(DBI)

ext  <- Sys.getenv("OG_EXT",  "./opengauss_scanner.duckdb_extension")
conn <- Sys.getenv("OG_CONN", "host=127.0.0.1 port=5432 dbname=test user=root password=Passwd@123")

# 关键: 在 driver 的 config 里开启; 连上后再 SET 会报错(启动期设置)。
con <- dbConnect(duckdb::duckdb(), config = list(allow_unsigned_extensions = "true"))

dbExecute(con, sprintf("LOAD '%s'", ext))
dbExecute(con, sprintf("ATTACH '%s' AS og (TYPE opengauss)", conn))

print(dbGetQuery(con, "SELECT * FROM og.public.t ORDER BY id"))

dbDisconnect(con, shutdown = TRUE)
