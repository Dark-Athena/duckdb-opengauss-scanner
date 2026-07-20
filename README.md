# duckdb-opengauss-scanner

基于 [duckdb-postgres](https://github.com/duckdb/postgres_scanner)(postgres_scanner) 构建面向
**openGauss 家族**(openGauss / MogDB / VastBase / PanWeiDB / GaussDB) 的 DuckDB 可加载扩展。

相比原版 postgres_scanner，本扩展解决三个关键差异：

- **免手动 SET 协议**：openGauss 的 COPY 二进制流与标准 PostgreSQL 不完全兼容。扩展默认启用
  TEXT 协议(`opengauss_use_text_protocol=true`)，无需每次连接后手动 `SET`。
- **原生 sha256 认证**：openGauss 家族默认口令加密为 sha256。原版需把服务端降级为 md5 才能连接；
  本扩展链接 openGauss 自带的 libpq，**直接支持 sha256，无需安全降级**。
- **可与官方 postgres_scanner 共存**：所有对外标识符全量改名为 `opengauss` 前缀(TYPE `opengauss`、
  `opengauss_*` 函数、secret 类型 `opengauss`)，与官方 `postgres_scanner` 完全不重叠，可在同一
  DuckDB 实例内同时加载、分别连接原生 PostgreSQL 与 openGauss/GaussDB。

---

## 一、设计原则

1. **不改上游源码**：构建前对少量文件打临时补丁，构建结束(含失败/中断)后由 `trap` **自动还原**，
   保证 `duckdb-postgres` 的 git 工作区始终干净。
2. **无需 openGauss 源码**：只链接指定目录下 openGauss **已编译好的 libpq(.so)**。
3. **可移植 bundle**：产物扩展内置 `DT_RPATH=$ORIGIN/lib`，运行期从**扩展同级的 `lib/` 子目录**
   解析 libpq 及其 openGauss 专属 krb5/gss/crypto 依赖，与启动 DuckDB 的宿主语言
   (Java / C / Python / CLI) 及当前工作目录无关。

---

## 二、前置依赖

| 依赖 | 说明 |
|---|---|
| `cmake`、`make`、`g++` | 编译工具链(C++17) |
| `ninja` | 可选，指定 `--ninja` 时需要 |
| `python3` | 仅用于给上游源码打补丁(多行/正则/JSON 编辑 + fail-fast 校验)，几乎所有环境自带 |
| `libssl-dev` | 编译时需要 OpenSSL 开发头文件 |
| openGauss libpq | **使用者自备**(不随本仓库分发)，含 `include/libpq-fe.h` 与 `lib/libpq.so*`，构建时用 `--libpq-dir` 指定 |
| `duckdb-postgres` 子模块 | 本仓库以子模块形式引用，其内部还嵌套 `duckdb` 子模块，需递归拉取 |

### 获取源码(含嵌套子模块)

`duckdb-postgres` 是本仓库的子模块，且其内部还嵌套 `duckdb` 子模块，务必**递归**拉取：

```bash
# 新克隆
git clone --recursive https://github.com/Dark-Athena/duckdb-opengauss-scanner.git

# 或已克隆但未拉子模块
git submodule update --init --recursive
```

> openGauss libpq 不在仓库内，请自备后放到 `./libpq`(默认)或用 `--libpq-dir` 指定，目录结构见下节。

> ⚠️ **内存提示**：DuckDB 采用 unity build，单个编译单元约需 2GB 内存。若机器内存 ≤ 4GB，
> 请用 `--jobs 2`(甚至 `--jobs 1`)，否则可能触发 OOM killer(`Killed signal terminated program cc1plus`)。

---

## 三、libpq 目录结构

### 下载 openGauss libpq()

官方预编译 libpq 下载(按 CPU 架构选择)：

| 架构 | 下载链接 |
|---|---|
| x86_64 | <https://opengauss.obs.cn-south-1.myhuaweicloud.com/6.0.5/openEuler20.03/x86/openGauss-Libpq-6.0.5-openEuler20.03-x86_64.tar.gz> |
| aarch64 | <https://opengauss.obs.cn-south-1.myhuaweicloud.com/6.0.5/openEuler20.03/arm/openGauss-Libpq-6.0.5-openEuler20.03-aarch64.tar.gz> |

下载后解压，使解压结果符合下方目录结构，再用 `--libpq-dir` 指向该目录(默认 `./libpq`)：

```bash
# 以 x86_64 为例
curl -LO https://opengauss.obs.cn-south-1.myhuaweicloud.com/6.0.5/openEuler20.03/x86/openGauss-Libpq-6.0.5-openEuler20.03-x86_64.tar.gz
mkdir -p libpq && tar -xzf openGauss-Libpq-6.0.5-openEuler20.03-x86_64.tar.gz -C libpq --strip-components=1
# 校验: 应存在 libpq/include/libpq-fe.h 与 libpq/lib/libpq.so*
```

> 解压后若 `include/`、`lib/` 不在 `libpq/` 顶层，请自行调整 `--strip-components` 或移动目录，
> 确保最终形如下方结构。

### 目录结构要求

`--libpq-dir` 指向的目录需形如：

```
libpq/
├── include/
│   └── libpq-fe.h          # 头文件(校验其存在)
└── lib/
    ├── libpq.so / libpq.so.5 / libpq.so.5.5
    ├── libssl.so.3 / libcrypto.so.3
    └── lib*_gauss.so*      # openGauss 专属 krb5 / gss / com_err 等
```

如果连接华为GaussDB,建议使用华为官方提供的GaussDB的libpq，连接其他openGauss发行版也均建议使用发行厂家单独提供的libpq
---

## 四、使用方法

### 基本用法(全部使用默认路径)

```bash
./build_opengauss_scanner.sh
```

默认：`libpq-dir=./libpq`、`duckdb-postgres=./duckdb-postgres`、`output=./dist`、并发 = `nproc`。

### 常用示例

```bash
# 低内存机器：限制并发 + 用 ninja(失败时可一次性枚举全部编译错误)
./build_opengauss_scanner.sh --ninja --jobs 2

# 指定 libpq 与输出目录
./build_opengauss_scanner.sh --libpq-dir /opt/gauss/libpq --output /tmp/og_dist

# 调试版
./build_opengauss_scanner.sh --debug
```

### 参数说明

| 参数 | 默认值 | 说明 |
|---|---|---|
| `--libpq-dir DIR` | `./libpq` | openGauss libpq 目录(含 `include/` 与 `lib/`) |
| `--duckdb-postgres DIR` | `./duckdb-postgres` | postgres_scanner 源码目录(含 `duckdb` 子模块) |
| `--output DIR` | `./dist` | 产物输出目录 |
| `--jobs N` / `-j N` | `nproc` | 编译并发数 |
| `--debug` | 关(release) | 构建调试版本 |
| `--ninja` | 关(make) | 使用 ninja 生成器 |
| `-h` / `--help` | | 显示帮助 |

---

## 五、构建流程

脚本分三个阶段，一条命令完成"打补丁 → 构建 → 自动还原 → 打包 bundle"：

1. **阶段 1 — 打临时补丁**(结束后自动还原)
   - `Makefile` / `extension_config.cmake` / `CMakeLists.txt`：扩展改名为 `opengauss_scanner`
   - `CMakeLists.txt`：绕过 `find_package(PostgreSQL)`，改指向 openGauss libpq；注入
     `--disable-new-dtags`(老式 DT_RPATH 以传递给二级依赖) 与 `$ORIGIN/lib` rpath
   - `postgres_extension.cpp`：`opengauss_use_text_protocol` 默认 `false→true`；扩展入口宏改名
     (使入口符号变为 `opengauss_scanner_duckdb_cpp_init`)；secret 类型/函数、存储扩展键、
     per-connection state 键均改为独立命名
   - **全量重命名(与官方 postgres_scanner 同实例共存)**：所有对外函数 `postgres_*`/`pg_*` →
     `opengauss_*`(scan/scan_pushdown/query/attach/execute/binary/configure_pool/hstore_* 等)，
     TYPE `postgres_scanner`→`opengauss`，secret 类型 `postgres`/`rds`→`opengauss`/`opengauss_rds`，
     开关 `pg_use_text_protocol`→`opengauss_use_text_protocol`，并同步内部按名调用/判断处
   - `postgres_oauth.cpp`：替换为 no-op 桩(openGauss libpq 无新版 OAuth API)
   - `postgres_catalog.cpp` / `postgres_secret_storage.cpp`：`return x` → `return std::move(x)`
     (GCC11 + C++17 具名局部返回值隐式移动兼容)
   - `vcpkg.json`：移除 libpq 依赖(本构建不走 vcpkg)
2. **阶段 2 — 构建**：链接 openGauss libpq 编译扩展。失败且启用 `--ninja` 时，会用
   `ninja -k 0` 一次性枚举全部编译错误便于定位。
3. **阶段 3 — 打包 bundle**：收集扩展与运行时依赖到输出目录，生成 `USAGE.md`，并校验 rpath。

---

## 六、产物

构建成功后 `dist/`(或 `--output` 指定目录)结构：

```
dist/
├── opengauss_scanner.duckdb_extension   # 扩展本体
├── USAGE.md                             # 使用说明(自动生成)
└── lib/                                 # 运行时依赖(保留 libpq/lib 原目录结构与软链)
    ├── libpq.so*  libssl.so.3  libcrypto.so.3
    └── lib*_gauss.so*
```

> 📦 **整体移动**：`dist/` 可整体拷贝到其它机器/路径使用。移动时**必须保持扩展与 `lib/` 的相对位置**
> (rpath 是 `$ORIGIN/lib`)，不要把扩展单独拆出去。

---

## 七、使用扩展

```sql
-- 未签名扩展需 CLI 加 -unsigned 启动，或启动时开启 allow_unsigned_extensions
LOAD 'dist/opengauss_scanner.duckdb_extension';

-- 连接 openGauss 家族数据库(sha256 认证，无需 md5 降级)。
-- 注意: 本扩展已全量改名，ATTACH 使用 TYPE opengauss(不再是 TYPE postgres)。
ATTACH 'host=127.0.0.1 port=5432 dbname=postgres user=xxx password=xxx' AS og (TYPE opengauss);

-- 默认已启用 TEXT 协议(opengauss_use_text_protocol=true)，直接查询即可
SELECT * FROM og.public.your_table LIMIT 10;

-- 透传 SQL 到远端执行, 用 opengauss_query(对应官方的 postgres_query)
SELECT * FROM opengauss_query('og', 'SELECT version()');
```

> 🔀 **与官方 postgres_scanner 同实例共存**：本扩展的所有对外标识符都改成了 `opengauss` 前缀
> (TYPE `opengauss`、函数 `opengauss_query`/`opengauss_scan`/`opengauss_attach`/…、secret 类型
> `opengauss`、开关 `opengauss_use_text_protocol`)，与官方 `postgres_scanner`(TYPE `postgres`、
> `postgres_*`)完全不重叠。因此可在**同一个 DuckDB 实例**里同时 `LOAD` 两者，分别 `ATTACH` 原生
> PostgreSQL(`TYPE postgres`)与 openGauss/GaussDB(`TYPE opengauss`)，互不干扰。

---

## 八、功能自测

仓库提供 `test_opengauss_scanner.sh`，逐项验证加载、连接、协议、家族探测、元数据与原生扫描，
输出 PASS/FAIL 汇总(全通过退出码 0，便于接入 CI)：

```bash
# 默认参数
./test_opengauss_scanner.sh

# 指定连接信息
./test_opengauss_scanner.sh --host 127.0.0.1 --port 5432 --user gaussdb --password 'Xxx@123'

./test_opengauss_scanner.sh -h   # 查看全部选项
```

---

## 九、常见问题

| 现象 | 原因 / 处理 |
|---|---|
| `Killed signal terminated program cc1plus` | 内存不足触发 OOM。降低并发：`--jobs 2` 或 `--jobs 1`。 |
| `duckdb 子模块未拉取` | 执行 `git submodule update --init --recursive`。 |
| `找不到 .../libpq-fe.h` | `--libpq-dir` 指向的目录缺少 `include/libpq-fe.h`，检查 libpq 路径。 |
| 构建失败缺 OpenSSL | 安装 `libssl-dev`(Debian/Ubuntu)。 |
| `did not contain the expected entrypoint` | 扩展名与入口符号不匹配；本脚本已自动处理，如自行改名需同步入口宏。 |

---

## 十、指定 DuckDB 版本构建

DuckDB 版本由 `duckdb-postgres` 子模块内部的 `duckdb` 子模块 checkout 决定，**构建脚本本身不涉及版本选择**。
切换版本是在运行构建脚本**之前**完成的子模块操作。

> **当前默认已钉稳定版**：`duckdb-postgres` 指向提交 `47537a6`(*Bump submodules to 1.5.3*)，
> 其内部 `duckdb` 子模块为 **v1.5.3**(source id `14eca11bd9`)。因此产物只能被
> **官方 DuckDB v1.5.3** 加载(见下方"两个必须注意的点")。

### 方式 A(推荐)：切 `duckdb-postgres` 的稳定版 bump 提交

`duckdb-postgres` 仓库**不打 release tag**(它跟随 duckdb 主线，由 duckdb 每次发版时的 CI 发布)，
但历史里有明确的 `Bump submodules to X.Y.Z` 提交，其记录的 `duckdb` 子模块就是官方验证过、
能编译通过的配套稳定版，三者(源码 / duckdb / extension-ci-tools)自动互相兼容：

```bash
cd duckdb-postgres
# 找到目标稳定版的 bump 提交(例: 1.5.3)
git log --oneline --all --grep="Bump submodules to 1.5.3"
git checkout 47537a6                      # 换成查到的 bump 提交
git submodule update --init --recursive   # 对齐嵌套子模块(duckdb 会切到 v1.5.3)
cd ..
# 记录父仓库对子模块的新指向
git add duckdb-postgres && git commit -m "chore: pin duckdb-postgres to 1.5.3 (duckdb v1.5.3)"
```

### 方式 B：仅手动钉住内部 `duckdb` 子模块版本

在当前 `duckdb-postgres` 基础上只换 duckdb 版本：

```bash
cd duckdb-postgres/duckdb
git fetch --tags
git checkout v1.5.4                       # 目标 duckdb 版本
cd ../.. && git submodule update --init --recursive
```

> ⚠️ 若 `duckdb-postgres` 源码引用了目标 duckdb 中不存在的 API，会**编译失败**。跨大版本请优先用方式 A。

### 两个必须注意的点

1. **加载扩展的 DuckDB 必须版本一致**：可加载扩展的元数据绑定了构建时的 duckdb 版本，版本不符
   `LOAD` 会被拒(`... was built for DuckDB version 'vX' ...`)。最省事的做法是**用构建同时产出的
   CLI** `duckdb-postgres/build/release/duckdb`(即本次子模块的版本，天然匹配，测试脚本默认就用它)；
   若用外部 duckdb 需下载同一版本。
2. **切换版本后清理旧产物再编译**：`rm -rf duckdb-postgres/build dist`。

