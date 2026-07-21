// Rust demo (duckdb crate)。
//
// Cargo.toml 里加依赖(二选一):
//   duckdb = { version = "1", features = ["bundled"] }  # 自带 libduckdb, 最省事
//   duckdb = "1"                                          # 用系统已装的 libduckdb
// 运行: cargo run
use duckdb::{Config, Connection, Result};

fn main() -> Result<()> {
    let ext = std::env::var("OG_EXT").unwrap_or_else(|_| "./opengauss_scanner.duckdb_extension".into());
    let conn = std::env::var("OG_CONN")
        .unwrap_or_else(|_| "host=127.0.0.1 port=5432 dbname=test user=root password=Passwd@123".into());

    // 关键: 用 Config 开启后再建连(启动期设置)。
    let config = Config::default().allow_unsigned_extensions()?;
    let db = Connection::open_in_memory_with_flags(config)?;

    db.execute_batch(&format!("LOAD '{ext}';"))?;
    db.execute_batch(&format!("ATTACH '{conn}' AS og (TYPE opengauss);"))?;

    let mut stmt = db.prepare("SELECT id, name FROM og.public.t ORDER BY id")?;
    let rows = stmt.query_map([], |r| Ok((r.get::<_, i32>(0)?, r.get::<_, String>(1)?)))?;
    for row in rows {
        let (id, name) = row?;
        println!("{id}\t{name}");
    }
    Ok(())
}
