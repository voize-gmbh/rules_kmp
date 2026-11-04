package de.voize.bazel.testing;

import static org.junit.platform.engine.discovery.DiscoverySelectors.selectClass;
import static org.junit.platform.engine.discovery.DiscoverySelectors.selectClasspathRoots;
import static org.junit.platform.engine.discovery.DiscoverySelectors.selectMethod;

import java.io.IOException;
import java.io.PrintWriter;
import java.io.StringWriter;
import java.lang.reflect.Modifier;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Collections;
import java.util.Comparator;
import java.util.HashSet;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Optional;
import java.util.ServiceLoader;
import java.util.Set;
import java.util.concurrent.ConcurrentHashMap;
import java.util.regex.Pattern;
import java.util.zip.ZipEntry;
import java.util.zip.ZipFile;
import org.junit.platform.engine.DiscoverySelector;
import org.junit.platform.engine.Filter;
import org.junit.platform.engine.TestEngine;
import org.junit.platform.engine.TestExecutionResult;
import org.junit.platform.engine.support.descriptor.ClassSource;
import org.junit.platform.engine.support.descriptor.MethodSource;
import org.junit.platform.launcher.Launcher;
import org.junit.platform.launcher.LauncherDiscoveryRequest;
import org.junit.platform.launcher.PostDiscoveryFilter;
import org.junit.platform.launcher.TagFilter;
import org.junit.platform.launcher.TestExecutionListener;
import org.junit.platform.launcher.TestIdentifier;
import org.junit.platform.launcher.TestPlan;
import org.junit.platform.launcher.core.LauncherConfig;
import org.junit.platform.launcher.core.LauncherDiscoveryRequestBuilder;
import org.junit.platform.launcher.core.LauncherFactory;
import org.junit.platform.engine.FilterResult;

/**
 * Runs every JUnit Platform test (Jupiter, and JUnit 4 through the vintage engine) found in the
 * jars named by {@code -Dbazel.test.jars}, honouring Bazel's test filter, sharding and XML report
 * environment variables.
 */
public final class BazelJUnitRunner {
  public static void main(String[] args) throws IOException {
    List<Path> roots = new ArrayList<>();
    for (String p : System.getProperty("bazel.test.jars", "").split(":")) {
      if (!p.isEmpty()) {
        roots.add(Paths.get(p).toAbsolutePath());
      }
    }
    LauncherDiscoveryRequestBuilder request = LauncherDiscoveryRequestBuilder.request();
    String only = System.getenv("TESTBRIDGE_TEST_ONLY");
    List<DiscoverySelector> selectors = new ArrayList<>();
    if (only != null && !only.isEmpty() && only.matches("[\\w.$]+(#[\\w$]+)?")) {
      if (only.contains("#")) {
        selectors.add(selectMethod(only));
      } else if (Character.isUpperCase(only.substring(only.lastIndexOf('.') + 1).charAt(0))) {
        selectors.add(selectClass(only));
      }
    }
    if (selectors.isEmpty()) {
      if (Boolean.getBoolean("bazel.junit.gradleClassOrder")) {
        selectors.addAll(gradleOrderSelectors(roots));
      } else {
        selectors.addAll(selectClasspathRoots(new HashSet<>(roots)));
      }
    }
    request.selectors(selectors);
    List<Filter<?>> filters = new ArrayList<>();
    String include = System.getProperty("bazel.junit.includeTags", "");
    String exclude = System.getProperty("bazel.junit.excludeTags", "");
    if (!include.isEmpty()) {
      filters.add(TagFilter.includeTags(include.split(",")));
    }
    if (!exclude.isEmpty()) {
      filters.add(TagFilter.excludeTags(exclude.split(",")));
    }
    List<String> includeClasses = csvProperty("bazel.junit.includeClasses");
    List<String> excludeClasses = csvProperty("bazel.junit.excludeClasses");
    if (!includeClasses.isEmpty() || !excludeClasses.isEmpty()) {
      filters.add((PostDiscoveryFilter) d -> {
        String cls = className(d.getSource().orElse(null));
        if (cls == null) {
          return FilterResult.included("no class");
        }
        boolean included = includeClasses.isEmpty() || includeClasses.stream().anyMatch(cls::startsWith);
        return FilterResult.includedIf(included && excludeClasses.stream().noneMatch(cls::startsWith));
      });
    }
    if (only != null && !only.isEmpty() && selectors.size() > 0 && !only.matches("[\\w.$]+(#[\\w$]+)?")) {
      Pattern pattern = Pattern.compile(only);
      filters.add((PostDiscoveryFilter) d -> FilterResult.includedIf(
          !d.isTest() || pattern.matcher(displayPath(d.getSource().orElse(null), d.getDisplayName())).find()));
    }
    int totalShards = intEnv("TEST_TOTAL_SHARDS", 1);
    int shardIndex = intEnv("TEST_SHARD_INDEX", 0);
    if (totalShards > 1) {
      String statusFile = System.getenv("TEST_SHARD_STATUS_FILE");
      if (statusFile != null) {
        Files.write(Paths.get(statusFile), new byte[0]);
      }
      filters.add((PostDiscoveryFilter) d -> {
        String cls = className(d.getSource().orElse(null));
        if (cls == null) {
          return FilterResult.included("no class");
        }
        return FilterResult.includedIf(Math.floorMod(cls.hashCode(), totalShards) == shardIndex);
      });
    }
    request.filters(filters.toArray(new Filter<?>[0]));
    request.configurationParameter("junit.jupiter.extensions.autodetection.enabled",
        System.getProperty("junit.jupiter.extensions.autodetection.enabled", "false"));
    LauncherDiscoveryRequest discovery = request.build();

    String engineOrder = System.getProperty("bazel.junit.engineOrder", "");
    Launcher launcher = engineOrder.isEmpty()
        ? LauncherFactory.create()
        : LauncherFactory.create(LauncherConfig.builder()
            .enableTestEngineAutoRegistration(false)
            .addTestEngines(orderedEngines(Arrays.asList(engineOrder.split(","))))
            .build());
    XmlListener xml = new XmlListener();
    launcher.execute(discovery, xml);
    String xmlFile = System.getenv("XML_OUTPUT_FILE");
    if (xmlFile != null) {
      Files.write(Paths.get(xmlFile), xml.toXml().getBytes(StandardCharsets.UTF_8));
    }
    System.out.printf("%n%d tests, %d failed, %d skipped%n", xml.total, xml.failed, xml.skipped);
    // Like Gradle's test task: finding nothing to run means the target is misconfigured. A shard
    // or a --test_filter can legitimately match nothing.
    if (xml.total == 0 && (only == null || only.isEmpty()) && totalShards == 1) {
      System.out.println("No tests found in " + roots);
      System.exit(1);
    }
    System.exit(xml.failed > 0 ? 1 : 0);
  }

  /**
   * Selects the test jars' classes one at a time, in the order Gradle's test scanner finds them: a
   * depth-first walk with each directory sorted by name. Test classes run in selection order, and
   * some suites pass only in Gradle's. Inner classes are left to their enclosing class, as in Gradle.
   */
  private static List<DiscoverySelector> gradleOrderSelectors(List<Path> roots) throws IOException {
    List<DiscoverySelector> out = new ArrayList<>();
    ClassLoader loader = Thread.currentThread().getContextClassLoader();
    for (Path root : roots) {
      List<String> entries = new ArrayList<>();
      try (ZipFile jar = new ZipFile(root.toFile())) {
        for (ZipEntry entry : Collections.list(jar.entries())) {
          String name = entry.getName();
          if (name.endsWith(".class") && !name.startsWith("META-INF/") && !name.endsWith("-info.class")) {
            entries.add(name);
          }
        }
      }
      entries.sort(BazelJUnitRunner::comparePaths);
      for (String entry : entries) {
        Class<?> klass;
        try {
          klass = Class.forName(entry.substring(0, entry.length() - ".class".length()).replace('/', '.'), false, loader);
        } catch (Throwable e) {
          continue;
        }
        if (klass.getEnclosingClass() != null && !Modifier.isStatic(klass.getModifiers())) {
          continue;
        }
        out.add(selectClass(klass));
      }
    }
    return out;
  }

  /**
   * The test engines on the classpath, those named first in the given order. Engines run one after
   * another in this order; Gradle takes it from the classpath, and suites can depend on it.
   */
  private static TestEngine[] orderedEngines(List<String> order) {
    List<TestEngine> engines = new ArrayList<>();
    ServiceLoader.load(TestEngine.class).forEach(engines::add);
    engines.sort(Comparator.comparingInt(e -> {
      int i = order.indexOf(e.getId());
      return i < 0 ? order.size() : i;
    }));
    return engines.toArray(new TestEngine[0]);
  }

  private static int comparePaths(String a, String b) {
    String[] pa = a.split("/");
    String[] pb = b.split("/");
    for (int i = 0; i < Math.min(pa.length, pb.length); i++) {
      int c = pa[i].compareTo(pb[i]);
      if (c != 0) {
        return c;
      }
    }
    return Integer.compare(pa.length, pb.length);
  }

  /** The values of a comma-separated system property. */
  private static List<String> csvProperty(String name) {
    String v = System.getProperty(name, "");
    return v.isEmpty() ? List.of() : Arrays.asList(v.split(","));
  }

  private static int intEnv(String name, int def) {
    String v = System.getenv(name);
    return v == null || v.isEmpty() ? def : Integer.parseInt(v);
  }

  private static String className(Object source) {
    if (source instanceof MethodSource) {
      return ((MethodSource) source).getClassName();
    }
    if (source instanceof ClassSource) {
      return ((ClassSource) source).getClassName();
    }
    return null;
  }

  private static String displayPath(Object source, String display) {
    if (source instanceof MethodSource) {
      MethodSource m = (MethodSource) source;
      return m.getClassName() + "#" + m.getMethodName();
    }
    String cls = className(source);
    return cls != null ? cls + "#" + display : display;
  }

  /** Collects results into JUnit-style XML, one testsuite per test class. */
  static final class XmlListener implements TestExecutionListener {
    final Map<String, List<String>> suites = new LinkedHashMap<>();
    final Map<String, Long> starts = new ConcurrentHashMap<>();
    final Map<String, long[]> suiteStats = new LinkedHashMap<>();
    int total;
    int failed;
    int skipped;
    TestPlan plan;

    @Override
    public void testPlanExecutionStarted(TestPlan testPlan) {
      plan = testPlan;
    }

    @Override
    public void executionStarted(TestIdentifier id) {
      starts.put(id.getUniqueId(), System.nanoTime());
    }

    @Override
    public void executionSkipped(TestIdentifier id, String reason) {
      if (id.isTest()) {
        record(id, 0, "<skipped message=\"" + esc(reason) + "\"/>");
        skipped++;
        total++;
      }
    }

    @Override
    public void executionFinished(TestIdentifier id, TestExecutionResult result) {
      long start = starts.getOrDefault(id.getUniqueId(), System.nanoTime());
      double seconds = (System.nanoTime() - start) / 1e9;
      boolean container = !id.isTest();
      if (container && result.getStatus() == TestExecutionResult.Status.SUCCESSFUL) {
        return;
      }
      String body = "";
      if (result.getStatus() != TestExecutionResult.Status.SUCCESSFUL) {
        Throwable t = result.getThrowable().orElse(null);
        String type = result.getStatus() == TestExecutionResult.Status.ABORTED ? "skipped" : "failure";
        if (type.equals("skipped")) {
          skipped++;
          body = "<skipped message=\"" + esc(t == null ? "" : String.valueOf(t.getMessage())) + "\"/>";
        } else {
          failed++;
          StringWriter sw = new StringWriter();
          if (t != null) {
            t.printStackTrace(new PrintWriter(sw));
          }
          body = "<failure message=\"" + esc(t == null ? "" : String.valueOf(t.getMessage())) + "\" type=\""
              + esc(t == null ? "" : t.getClass().getName()) + "\">" + esc(sw.toString()) + "</failure>";
          System.err.println("FAILED: " + displayPath(id.getSource().orElse(null), id.getDisplayName()));
          System.err.println(sw);
        }
      }
      total++;
      record(id, seconds, body);
    }

    private void record(TestIdentifier id, double seconds, String body) {
      String cls = className(id.getSource().orElse(null));
      if (cls == null) {
        cls = id.getDisplayName();
      }
      String name = id.getSource().orElse(null) instanceof MethodSource
          ? ((MethodSource) id.getSource().get()).getMethodName() + (id.getDisplayName().contains("[") ? id.getDisplayName() : "")
          : id.getDisplayName();
      suites.computeIfAbsent(cls, k -> new ArrayList<>()).add(String.format(
          "    <testcase classname=\"%s\" name=\"%s\" time=\"%.3f\">%s</testcase>",
          esc(cls), esc(name), seconds, body));
    }

    String toXml() {
      StringBuilder b = new StringBuilder("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<testsuites>\n");
      for (Map.Entry<String, List<String>> e : suites.entrySet()) {
        b.append(String.format("  <testsuite name=\"%s\" tests=\"%d\">\n", esc(e.getKey()), e.getValue().size()));
        for (String tc : e.getValue()) {
          b.append(tc).append('\n');
        }
        b.append("  </testsuite>\n");
      }
      return b.append("</testsuites>\n").toString();
    }

    private static String esc(String s) {
      StringBuilder b = new StringBuilder();
      for (char c : s.toCharArray()) {
        switch (c) {
          case '<': b.append("&lt;"); break;
          case '>': b.append("&gt;"); break;
          case '&': b.append("&amp;"); break;
          case '"': b.append("&quot;"); break;
          default:
            if (c < 0x20 && c != '\n' && c != '\t' && c != '\r') {
              b.append(' ');
            } else {
              b.append(c);
            }
        }
      }
      return b.toString();
    }
  }
}
