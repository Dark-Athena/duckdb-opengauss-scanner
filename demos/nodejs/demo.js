// Node.js demo: npm install duckdb
// 运行: node nodejs/demo.js
//
// 若用新版 @duckdb/node-api(Neo):
//   const { DuckDBInstance } = require('@duckdb/node-api');
//   const inst = await DuckDBInstance.create(':memory:', { allow_unsigned_extensions: 'true' });
//   const conn = await inst.connect();
//   await conn.run(`LOAD '${ext}'`);  ...
const duckdb = require('duckdb');

const ext = process.env.OG_EXT || './opengauss_scanner.duckdb_extension';
const conn = process.env.OG_CONN || 'host=127.0.0.1 port=5432 dbname=test user=root password=Passwd@123';

// 关键: 在 new Database 的第二个参数(config)里开启; 值必须是字符串。
const db = new duckdb.Database(':memory:', { allow_unsigned_extensions: 'true' });

db.exec(`LOAD '${ext}';`, (e1) => {
  if (e1) throw e1;
  db.exec(`ATTACH '${conn}' AS og (TYPE opengauss);`, (e2) => {
    if (e2) throw e2;
    db.all('SELECT * FROM og.public.t ORDER BY id', (e3, rows) => {
      if (e3) throw e3;
      console.log(rows);
      db.close();
    });
  });
});
