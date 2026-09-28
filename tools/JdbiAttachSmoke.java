import java.io.File;
import java.lang.reflect.Modifier;
import java.lang.reflect.Proxy;
import java.sql.Connection;
import java.util.ArrayList;
import java.util.Collections;
import java.util.Enumeration;
import java.util.List;
import java.util.jar.JarEntry;
import java.util.jar.JarFile;

import org.jdbi.v3.core.Jdbi;
import org.jdbi.v3.sqlobject.SqlObjectPlugin;

/**
 * Smoke test for the JDBI SqlObject wiring of openmetadata-service, run without a database.
 *
 * Attaching a DAO interface makes JDBI build the extension metadata for every method: it
 * instantiates the SQL handlers referenced by the method annotations and resolves all
 * binder/customizer classes. This is exactly the step that fails with a ClassCastException when
 * jdbi3-sqlobject is newer than what openmetadata-service was compiled against, and it happens
 * only after a DB connection is open, so the Dropwizard `check` command never reaches it.
 * A JDBC Connection proxy that answers with defaults is enough, because no statement is executed.
 *
 * Without arguments every interface named *DAO under org.openmetadata.service.jdbi3 (including
 * the nested CollectionDAO$XxxDAO interfaces) found in the openmetadata-service jar is attached,
 * except template interfaces that other DAOs extend (EntityDAO, EntityTimeSeriesDAO, ...).
 *
 * Usage (single-file source launch, JDK 11+):
 *   java -cp "libs/*" tools/JdbiAttachSmoke.java [dao-class ...]
 */
public class JdbiAttachSmoke {

  private static final String DAO_PACKAGE_PREFIX = "org/openmetadata/service/jdbi3/";

  public static void main(String[] args) throws Exception {
    List<String> daos = args.length > 0 ? List.of(args) : discoverDaos();
    if (daos.isEmpty()) {
      System.out.println("JdbiAttachSmoke: no DAO interfaces found");
      System.exit(1);
    }

    Connection connection = (Connection) Proxy.newProxyInstance(
        JdbiAttachSmoke.class.getClassLoader(),
        new Class<?>[] {Connection.class},
        (proxy, method, methodArgs) -> {
          Class<?> r = method.getReturnType();
          if (r == boolean.class) return false;
          if (r == int.class) return 0;
          if (r == long.class) return 0L;
          if (r == String.class) return "";
          return null;
        });

    Jdbi jdbi = Jdbi.create(() -> connection);
    jdbi.installPlugin(new SqlObjectPlugin());

    int failures = 0;
    for (String dao : daos) {
      try (var handle = jdbi.open()) {
        handle.attach(Class.forName(dao));
      } catch (Throwable t) {
        failures++;
        System.out.println("JdbiAttachSmoke: FAIL " + dao);
        t.printStackTrace(System.out);
      }
    }
    System.out.println("JdbiAttachSmoke: attached " + (daos.size() - failures) + "/" + daos.size()
        + " DAO interfaces from openmetadata-service");
    if (failures > 0) {
      System.out.println("JdbiAttachSmoke: " + failures + " DAO(s) could not be attached; "
          + "jdbi3-sqlobject on the classpath is incompatible with openmetadata-service");
      System.exit(1);
    }
  }

  /** Every interface named *DAO in the service jar's jdbi3 package, nested interfaces included. */
  private static List<String> discoverDaos() throws Exception {
    Class<?> anchor = Class.forName("org.openmetadata.service.jdbi3.CollectionDAO");
    File jar = new File(anchor.getProtectionDomain().getCodeSource().getLocation().toURI());
    List<String> result = new ArrayList<>();
    try (JarFile jf = new JarFile(jar)) {
      for (Enumeration<JarEntry> e = jf.entries(); e.hasMoreElements();) {
        String name = e.nextElement().getName();
        if (!name.startsWith(DAO_PACKAGE_PREFIX) || !name.endsWith("DAO.class")) continue;
        String className = name.substring(0, name.length() - ".class".length()).replace('/', '.');
        Class<?> c = Class.forName(className, false, anchor.getClassLoader());
        if (c.isInterface() && Modifier.isPublic(c.getModifiers())) result.add(className);
      }
    }
    // Template interfaces such as EntityDAO<T> declare abstract non-SQL methods that concrete DAOs
    // implement; JDBI can attach only the concrete ones. Skip every interface another DAO extends.
    List<Class<?>> classes = new ArrayList<>();
    for (String n : result) classes.add(Class.forName(n, false, anchor.getClassLoader()));
    List<String> concrete = new ArrayList<>();
    for (Class<?> c : classes) {
      boolean extended = false;
      for (Class<?> other : classes) {
        if (other != c && c.isAssignableFrom(other)) { extended = true; break; }
      }
      if (!extended) concrete.add(c.getName());
    }
    Collections.sort(concrete);
    return concrete;
  }
}
