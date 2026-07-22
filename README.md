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
| `cmake`、`make`、`g++` | 编译工具链(C++17)。**GCC 必须 ≥ 8**(推荐 11+)，见[第十一节](#十一duckdb-官方预编译版本的编译依赖链)。GCC 7 会在链接期报 `undefined reference to std::allocator<...>::allocator()` |
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

**如果连接华为GaussDB,建议使用华为官方提供的GaussDB的libpq，连接其他openGauss发行版也均建议使用发行厂家单独提供的libpq**

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

> 📦 **各语言客户端示例**：CLI / Python / C / Node.js / ODBC / R / Rust / Java 如何"开启允许未签名扩展
> → `LOAD` → `ATTACH` 查询"的可运行 demo，见 [`demos/`](demos/README.md)。关键点：`allow_unsigned_extensions`
> 是启动期设置，必须在建连/建库那一刻通过 config/连接属性/`-unsigned` 给出，连上后再 `SET` 会报错。

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

要编译哪个/哪些 DuckDB 版本, 由仓库根的 **`duckdb_versions.json`** 决定 —— 这是**唯一事实源**。

```jsonc
{
  "default": "v1.5.4",                 // 未指定版本时的默认(普通/本地构建)
  "versions": {
    // DuckDB 版本 tag  ->  duckdb-postgres 的官方 pin 完整 commit SHA
    // 该 SHA 取自 duckdb/duckdb 在该版本 tag 冻结的
    //   .github/config/extensions/postgres_scanner.cmake 的 GIT_TAG
    // (可用 scripts/resolve_pg_ref.sh <版本> 解析)。
    "v1.5.4": "8f813f9b9c9e52a9074a050a0be60f49160a6baa",
    "v1.5.3": "6b2b12cad3afef61e8a4637e714e8a88895fed1a",
    "v1.4.5": "b9fce43bc5d36bc6db70844f28b7b146e756eb22"
  }
}
```

> **为什么用官方 pin SHA(而不是分支/版本号/Bump 提交)**:`duckdb-postgres` 不打 release tag。
> 我们统一采用**官方口径** —— 即 `duckdb/duckdb` 主仓库在各版本 tag 里冻结的 `postgres_scanner`
> 源码 commit。这是对**任何**版本(含分支已被删的 EOL 版本, 如 `v1.4.5`)都通用的权威来源。
>
> 注意:官方 pin 自带的**嵌套 `duckdb` 子模块可能滞后**目标版本(例如 v1.5.4 的 pin 内嵌 v1.5.3)。
> 构建时由 `scripts/select_duckdb.sh` 把嵌套 `duckdb` **强制覆盖**到目标版本 tag —— 等价于官方
> 发布流程里的 `make set_duckdb_version`。因此"指定 DuckDB 版本"最终决定实际编译哪个 DuckDB。

### 在 CI 里构建指定版本(推荐)

到 GitHub Actions 手动运行 **Build & Release**(`workflow_dispatch`), 选 `duckdb_version`:

- `all` —— 构建清单里**全部**版本(打 `v*` tag 发布时也是这个行为)
- `default` —— 只构建清单 `default` 指定的版本
- 指定版本(如 `v1.5.4`)—— 只构建该版本

CI 会调用 `scripts/select_duckdb.sh <版本> <官方pin>` 把 `duckdb-postgres` 切到清单登记的官方 pin、
把嵌套 `duckdb` 强制覆盖到目标版本, 并以 `OVERRIDE_GIT_DESCRIBE=<版本>` 把扩展**正确戳成该 DuckDB
版本**, 产物名带版本号(见[第十二节](#十二github-actions-自动化构建与发布))。

### 新增一个 DuckDB 版本(维护步骤)

用 `scripts/resolve_pg_ref.sh` 解析该版本的官方 pin(读 `duckdb/duckdb` 对应 tag 冻结的
`postgres_scanner.cmake` 的 `GIT_TAG`, 对 EOL 版本同样适用):

```bash
scripts/resolve_pg_ref.sh v1.5.5      # -> stdout 打印完整 40 位 SHA; stderr 打印核对信息
```

然后改两处(仅这两处):

1. `duckdb_versions.json` 的 `versions` 里加一行:`"v1.5.5": "<完整SHA>"`(需要的话改 `default`)。
2. `.github/workflows/build.yml` 里 `workflow_dispatch.inputs.duckdb_version.options` 加一项 `v1.5.5`
   (仅为下拉菜单便利;实际解析以清单为准)。

> 跨**大版本**(如 1.5 → 1.6)时, 我们对 `duckdb-postgres` 打的 rebrand/sha256/TEXT 补丁锚点可能
> 变化, 首次构建需留意补丁是否踩空。补丁点集中在 `Makefile` / `extension_config.cmake` /
> `CMakeLists.txt` 及少数 `src/*.cpp`。

### 本地构建指定版本

最省事是把版本号直接交给构建脚本 —— 它会调用 `scripts/select_duckdb.sh` 走官方口径切换
(切到官方 pin + 覆盖嵌套 duckdb 到目标版本), 并自动以该版本作为版本戳:

```bash
rm -rf duckdb-postgres/build dist                        # 切版本前务必清理旧产物
./build_opengauss_scanner.sh --duckdb-version v1.4.5 --ninja
```

> `--duckdb-version` 对分支已删的 **EOL 版本(如 `v1.4.5`)同样有效** —— 只要该版本已在
> `duckdb_versions.json` 登记。省略该参数时, 脚本直接构建 `duckdb-postgres` 的**当前 checkout**,
> 并从嵌套 `duckdb` 的 `git describe --tags` 自动推导版本戳, 无需手动设 `OVERRIDE_GIT_DESCRIBE`。

也可先单独切换再构建(等价, 便于排查):

```bash
scripts/select_duckdb.sh v1.4.5      # 官方口径切换(幂等; 已在目标状态则跳过网络操作)
rm -rf duckdb-postgres/build dist
./build_opengauss_scanner.sh --ninja
# 如需强制指定版本戳: OVERRIDE_GIT_DESCRIBE=v1.4.5 ./build_opengauss_scanner.sh ...
```

### 两个必须注意的点

1. **加载扩展的 DuckDB 必须版本一致**:扩展元数据绑定了构建时的 duckdb 版本, 版本不符 `LOAD`
   会被拒(`... was built for DuckDB version 'vX' ...`;若戳成 `v0.0.1` 则说明版本戳未生效)。
   最省事是**用构建同时产出的 CLI** `duckdb-postgres/build/release/duckdb`(天然匹配, 测试脚本默认
   就用它);用外部 duckdb 需下载**同一版本**。
2. **切换版本后清理旧产物再编译**:`rm -rf duckdb-postgres/build dist`。

### 1.4.x (LTS) 与 1.5.x 的架构差异

`v1.4.5` 是 DuckDB 官网当前的 **LTS 版本**, 本仓库已完整支持。需要注意 `duckdb-postgres`
在 1.4.x 与 1.5.x 用了**两套完全不同的 libpq 获取方式**, 构建脚本用**特性探测(feature-probing,
按锚点/文件存在与否, 而非硬编码版本号)**自动选对补丁, 因此 `--duckdb-version` 对两代都适用:

| | 1.5.x | 1.4.x (LTS) |
|---|---|---|
| libpq 来源 | `find_package(PostgreSQL REQUIRED)` 链接预编译 libpq | 下载 PostgreSQL 15.13 源码 + `./configure` 把 PG 官方 libpq 静态编进扩展 |
| 本仓库补丁 | 替换 `find_package(PostgreSQL)` 为指向 openGauss libpq 的 IMPORTED target | **移除**"下载/编译 PG 源码"逻辑, 改链外部 openGauss libpq(`OPENSSL_USE_STATIC_LIBS` 也随之改 `FALSE`) |
| secret/storage 注册 | 分散在 `postgres_secrets.cpp` 等, 用 `StorageExtension::Register(...)` | 集中在 `postgres_extension.cpp`, 用 `config.storage_extensions[...]` |
| 缺失的文件/特性 | 齐全 | 无 `postgres_oauth`/`aws`/`hstore`/`logging`/`configure_pool`/`secret_storage`, 无 `read_postgres_binary`/`RemoteExecute`(相关补丁"存在才打", 自动跳过) |

> 无论哪代, 最终都**只链接外部 openGauss libpq** —— openGauss 家族的 sha256 认证依赖其自带
> libpq, PostgreSQL 官方 libpq 不识别, 故 1.4.x 也必须移除内嵌的 PG libpq。

---

## 十一、DuckDB 官方预编译版本的编译依赖链

本项目产物是 DuckDB **可加载扩展**，最终要被官方发行的 DuckDB 加载运行。官方的 Linux 预编译
二进制(含 CLI 与扩展)全部在**固定的容器工具链**里构建，其配置直接来自
`duckdb-postgres/extension-ci-tools/docker/*/Dockerfile`(由 duckdb 发版 CI 调用)。要让自编译的
扩展与官方运行时二进制/ABI 匹配，本地编译环境应尽量向这条链看齐。

### 官方各平台工具链一览

| 平台 (`DUCKDB_PLATFORM`) | 基础镜像 | 发行版 | 编译器 | glibc / libc 基线 |
|---|---|---|---|---|
| `linux_amd64` | `quay.io/pypa/manylinux_2_28_x86_64` | AlmaLinux 8 | **GCC(gcc-toolset)**，当前 GCC 14 | **glibc ≥ 2.28** |
| `linux_arm64` | `quay.io/pypa/manylinux_2_28_aarch64` | AlmaLinux 8 | **GCC(gcc-toolset)**，当前 GCC 14 | **glibc ≥ 2.28** |
| `linux_amd64_musl` | `alpine:3.22` | Alpine | GCC / clang19 | musl libc |
| `linux_arm64_musl` | `alpine:*`(同上) | Alpine | GCC / clang19 | musl libc |

补充要点(来自 Dockerfile 与 manylinux 官方说明)：

- **glibc 基线 2.28**：`manylinux_2_28` 保证产物可在 glibc ≥ 2.28 的发行版运行
  (Debian 10+ / Ubuntu 18.10+ / CentOS·RHEL 8+ / **Kylin V10**)。这是"最低运行门槛"，
  本地 glibc **等于或高于** 2.28 都可以。
- **编译器为较新的 GCC**：manylinux 镜像随时间升级其 gcc-toolset(历史上 11→12→13，当前为
  **GCC 14**)。官方并不用某个精确的 GCC 小版本，但**都是 GCC 8 以上的现代版本**。
- **构建系统**：CMake(官方镜像用 4.0.2) + **Ninja**(`GEN=ninja`) + ccache；vcpkg 提供第三方依赖。
  本项目不强制这些(用系统 CMake≥3.5、Makefiles 或 Ninja 均可)，仅编译器版本是硬约束。

### 对本地/自编译环境的要求

| 项目 | 要求 | 说明 |
|---|---|---|
| **GCC** | **≥ 8，推荐 11+** | DuckDB 源码是 C++17。**GCC 7 会失败**:链接期报 `undefined reference to std::allocator<duckdb::Value>::allocator()` —— 这是 GCC 7 libstdc++ 对部分模板类型未内联发射 `allocator` 默认构造函数的已知缺陷，GCC 8 已修复。要贴近官方可用 GCC 11+。 |
| **glibc** | **≥ 2.28** | 与官方 `manylinux_2_28` 一致即可;低于 2.28 也许能自编译,但产物无法在官方运行时环境保证兼容。 |
| CMake | ≥ 3.5 | duckdb v1.5.3 声明 `cmake_minimum_required(3.5...3.29)`;`CMAKE_CXX_STANDARD=11`,实际按源码需要拉到 C++17。 |
| clang | 亦可 | 官方 musl 镜像用 clang19;若本地用 clang,版本需完整支持 C++17。 |

> 💡 **为什么 Kylin V10 / 老 CentOS 8 上默认 gcc 7.3.0 编不过**:这类系统 **glibc 2.28 达标**,
> 但**自带 GCC 7 过老**。解决办法是装一个更新的 GCC 后再构建,例如:
> ```bash
> # openEuler / Kylin V10(dnf/yum):安装 gcc-toolset
> sudo dnf install -y gcc-toolset-11-gcc gcc-toolset-11-gcc-c++
> source /opt/rh/gcc-toolset-11/enable   # 仅当前 shell 生效
> gcc --version                          # 确认 >= 8(此处为 11)
> # 然后照常运行构建脚本
> ./build_opengauss_scanner.sh --jobs 8
> ```
> 若源不含 `gcc-toolset`,可从源码编译 GCC 11+ 或改用具备新版 GCC 的构建机;
> 最贴近官方的做法是直接在 `manylinux_2_28` 容器内构建。

---

## 十二、GitHub Actions 自动化构建与发布

仓库内置 `.github/workflows/build.yml`,**按 DuckDB 官方构建方案**(在
`quay.io/pypa/manylinux_2_28_{x86_64,aarch64}` 容器内, gcc-toolset / glibc 2.28)自动产出
可分发压缩包。产物 = **(清单里选中的 DuckDB 版本数) × 2 variant × 2 platform**, 命名带版本号
`opengauss_scanner-<variant>-<platform>-<duckdb_version>.zip`:

| variant | platform | 压缩包(以 v1.5.4 为例) | 使用的 libpq |
|---|---|---|---|
| openGauss | linux_amd64 | `opengauss_scanner-opengauss-linux_amd64-v1.5.4.zip` | openGauss 官方预编译 libpq(x86_64) |
| openGauss | linux_arm64 | `opengauss_scanner-opengauss-linux_arm64-v1.5.4.zip` | openGauss 官方预编译 libpq(aarch64) |
| GaussDB | linux_amd64 | `opengauss_scanner-gaussdb-linux_amd64-v1.5.4.zip` | 华为 GaussDB 驱动包 **Kylin V10 / X86_64** 版 libpq |
| GaussDB | linux_arm64 | `opengauss_scanner-gaussdb-linux_arm64-v1.5.4.zip` | 华为 GaussDB 驱动包 **Kylin V10 / arm_64** 版 libpq |

- **构建哪些 DuckDB 版本**:由 `duckdb_versions.json` + 触发时的选择决定(见[第十节](#十指定-duckdb-版本构建))。
- **openGauss libpq**:直接下载[第三节](#三libpq-目录结构)给出的官方 tar.gz。
- **GaussDB libpq**:参照华为
  [install_gaussdb_driver.sh](https://github.com/huaweicloud-samples/database-gaussdb-python/blob/master/tools/install_gaussdb_driver.sh)
  的方式下载 `GaussDB_driver.zip`,但**只取 `Centralized/Kylinv10_<ARCH>/` 里的 libpq**。
- **自动测试**:在 `linux_amd64` 与 `linux_arm64` 上各自拉起
  [opengauss docker](https://github.com/huaweicloud-samples/database-gaussdb-python/blob/master/.github/workflows/tests.yml)
  (`opengauss/opengauss-server:latest` 为 amd64/arm64 多架构镜像, 各 runner 自动拉对应架构),用**本次同版本产出的 DuckDB CLI** 做
  `LOAD` + `ATTACH (TYPE opengauss)` + 查询的冒烟测试(两种 variant 都测:GaussDB 版扩展同样以
  sha256 连接 openGauss 服务端)。
- **发布**:推送 `v*` tag 时,自动构建清单里**全部**版本并把压缩包挂到 GitHub Release。

触发方式(**普通 push / PR 不再自动构建**, 完全手动控制何时编译):

- **`workflow_dispatch`**(手动):选 `duckdb_version` = `all` / `default` / 指定版本。
- **打 `v*` tag**:构建清单全部版本并发布 Release。

> arm64 构建与测试均在 GitHub 托管的 `ubuntu-24.04-arm` 原生 runner 上进行(非 QEMU 模拟),
> 与 amd64 同等覆盖(构建 + 加载/连接/查询冒烟测试)。


