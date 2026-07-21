# 各客户端加载 opengauss_scanner 扩展的 Demo

本目录演示在不同客户端里 **① 开启"允许未签名扩展" → ② `LOAD` 扩展 → ③ `ATTACH` 并查询** 的完整三步。

## 一条必须记住的规则

`allow_unsigned_extensions` 是 **启动期设置**——只能在**打开数据库/建立连接的那一刻**给，
连上之后再 `SET` 会报错（`Cannot change allow_unsigned_extensions setting while database is running`）。
所以每种客户端都是通过"建连时的 config / 连接属性 / 启动 flag"来开启，而不是执行一条 SQL。

| 客户端 | 开启方式 |
|---|---|
| CLI | 启动加 `-unsigned` |
| Python | `duckdb.connect(config={"allow_unsigned_extensions":"true"})` |
| C | `duckdb_set_config(cfg, "allow_unsigned_extensions", "true")` 后 `duckdb_open_ext` |
| Node.js | `new duckdb.Database(":memory:", {allow_unsigned_extensions:"true"})` |
| ODBC | 连接串加 `allow_unsigned_extensions=true` |
| R | `dbConnect(duckdb::duckdb(), config=list(allow_unsigned_extensions="true"))` |
| Rust | `Config::default().allow_unsigned_extensions()?` |
| Java (JDBC) | 连接 `Properties` 里 `allow_unsigned_extensions=true` |

## 共用参数（所有 demo 都读这两个环境变量，未设则用默认值）

```bash
# 扩展文件路径。注意: 请让 lib/ 目录与 .duckdb_extension 保持在一起
# (扩展用 $ORIGIN/lib 的 rpath 找依赖库), 否则 LOAD 会因缺依赖失败。
export OG_EXT="/abs/path/to/opengauss_scanner.duckdb_extension"

# openGauss / GaussDB 连接串(libpq 格式)
export OG_CONN="host=127.0.0.1 port=5432 dbname=test user=root password=Passwd@123"
```

> 扩展的 ATTACH 类型名是 `opengauss`，即 `ATTACH '<conn>' AS og (TYPE opengauss)`；默认走 TEXT 协议、原生 sha256 认证。

## 各 demo 如何跑

| 文件 | 运行 |
|---|---|
| [cli/demo.sh](cli/demo.sh) | `bash cli/demo.sh` |
| [python/demo.py](python/demo.py) | `pip install duckdb && python python/demo.py` |
| [c/demo.c](c/demo.c) | 见文件头注释（gcc 编译，链接 libduckdb） |
| [nodejs/demo.js](nodejs/demo.js) | `npm i duckdb && node nodejs/demo.js` |
| [odbc/demo.py](odbc/demo.py) | 装 DuckDB ODBC 驱动 + `pip install pyodbc`，见文件头 |
| [r/demo.R](r/demo.R) | `Rscript r/demo.R` |
| [rust/main.rs](rust/main.rs) | 见文件头（`cargo run`） |
| [java/Demo.java](java/Demo.java) | 见文件头（`javac`/`java` 带 `duckdb_jdbc.jar`） |

## 想彻底不用每次开 unsigned？

- **CLI**：`~/.bashrc` 里 `alias duckdb='duckdb -unsigned'`，再在 `~/.duckdbrc` 里写 `LOAD '<OG_EXT>';` 自动加载。
- **应用/客户端**：把开启项固化进你的连接封装即可（如上表）。
- **真正"签名、零 flag"**：只能把扩展发布到 DuckDB Community Extensions（需开源、走官方 CI/签名）。
