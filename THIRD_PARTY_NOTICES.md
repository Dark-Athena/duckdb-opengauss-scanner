# Third-Party Notices

`duckdb-opengauss-scanner` itself is licensed under the MIT License (see
[LICENSE](./LICENSE)). This document lists third-party components used and/or
redistributed by this project, together with their respective licenses.

Two categories are covered:

1. **Source dependencies** — code this project builds upon (patched at build
   time, not vendored into the repository).
2. **Bundled binaries** — shared libraries shipped inside the release
   distribution (`dist/lib/`), required at runtime by the loadable extension.

---

## 1. Source dependencies

| Component | Role | License | Copyright |
|---|---|---|---|
| [DuckDB](https://github.com/duckdb/duckdb) | Host engine / extension API | MIT | Stichting DuckDB Foundation |
| [duckdb-postgres (postgres_scanner)](https://github.com/duckdb/duckdb-postgres) | Base extension this project is derived from | MIT | Stichting DuckDB Foundation |

This project rebrands and patches `postgres_scanner` at build time to target the
openGauss database family; the resulting derivative remains under the MIT License.

---

## 2. Bundled binaries (`dist/lib/`)

The release bundle ships the openGauss client library (`libpq`) and its runtime
dependency closure so the extension is portable. These are **not** authored by
this project and retain their original licenses:

| Library (soname) | Component | License |
|---|---|---|
| `libpq.so.5*`, `libpq_ce.so.*` | openGauss client library (libpq) | Mulan PSL v2 |
| `libpgport_tool.so.*` | openGauss port utilities | PostgreSQL License |
| `libgssapi_krb5_gauss.so.*`, `libgssrpc_gauss.so.*`, `libk5crypto_gauss.so.*`, `libkrb5_gauss.so.*`, `libkrb5support_gauss.so.*`, `libcom_err_gauss.so.*` | MIT Kerberos 5 (openGauss build) | MIT (MIT Kerberos License) |
| `libssl.so.1.1`, `libcrypto.so.1.1` | OpenSSL 1.1.x | OpenSSL License + SSLeay License |
| `libcjson.so.*` | cJSON | MIT |
| `libconfig.so.*` | libconfig | LGPL-2.1-or-later |

Notes:

- **openGauss (Mulan PSL v2)**: full text at
  <https://license.coscl.org.cn/MulanPSL2>. The openGauss project and its
  `libpq` are distributed under Mulan PSL v2; redistribution must retain the
  copyright and license notices.
- **OpenSSL 1.1.x**: dual-licensed under the OpenSSL License and the original
  SSLeay License (OpenSSL 3.x switched to Apache-2.0; the bundled binaries here
  are the 1.1 series shipped with openGauss).
- **libconfig (LGPL-2.1-or-later)**: dynamically linked (shared object); this
  satisfies the LGPL relinking condition. Source is available from
  <https://github.com/hyperrealm/libconfig>.
- The exact upstream version, source, and license text of each bundled library
  follow the openGauss release from which the `libpq/` client package was taken.

If you redistribute the release bundle, keep this file alongside it to comply
with the above notices.
