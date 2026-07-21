// Java demo (JDBC)。依赖 org.duckdb:duckdb_jdbc。
//
// 取 jar: 从 Maven 下 duckdb_jdbc(如 duckdb_jdbc-1.5.x.jar), 记为 $JAR
// 编译: javac -cp "$JAR" java/Demo.java -d /tmp
// 运行:
//   OG_EXT=/abs/opengauss_scanner.duckdb_extension \
//   OG_CONN="host=127.0.0.1 port=5432 dbname=test user=root password=Passwd@123" \
//   java -cp "/tmp:$JAR" Demo
import java.sql.Connection;
import java.sql.DriverManager;
import java.sql.ResultSet;
import java.sql.Statement;
import java.util.Properties;

public class Demo {
    public static void main(String[] args) throws Exception {
        String ext = System.getenv().getOrDefault("OG_EXT", "./opengauss_scanner.duckdb_extension");
        String conn = System.getenv().getOrDefault(
                "OG_CONN", "host=127.0.0.1 port=5432 dbname=test user=root password=Passwd@123");

        // 关键: 通过连接属性开启(建连即启动期); 连上后再 SET 会报错。
        Properties props = new Properties();
        props.setProperty("allow_unsigned_extensions", "true");

        try (Connection c = DriverManager.getConnection("jdbc:duckdb:", props);
             Statement st = c.createStatement()) {
            st.execute("LOAD '" + ext + "'");
            st.execute("ATTACH '" + conn + "' AS og (TYPE opengauss)");
            try (ResultSet rs = st.executeQuery("SELECT * FROM og.public.t ORDER BY id")) {
                int cols = rs.getMetaData().getColumnCount();
                while (rs.next()) {
                    StringBuilder sb = new StringBuilder();
                    for (int i = 1; i <= cols; i++) {
                        sb.append(rs.getString(i)).append('\t');
                    }
                    System.out.println(sb);
                }
            }
        }
    }
}
