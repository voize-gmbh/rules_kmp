package de.voize.bazel.kotlin;

import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.io.PrintStream;
import java.io.RandomAccessFile;
import java.lang.reflect.Method;
import java.net.URL;
import java.net.URLClassLoader;
import java.nio.charset.StandardCharsets;
import java.nio.file.FileVisitResult;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.nio.file.SimpleFileVisitor;
import java.nio.file.StandardCopyOption;
import java.nio.file.attribute.BasicFileAttributes;
import java.time.LocalDateTime;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Enumeration;
import java.util.HashMap;
import java.util.LinkedHashMap;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Map;
import java.util.Properties;
import java.util.Set;
import java.util.TreeMap;
import java.util.zip.ZipEntry;
import java.util.zip.ZipFile;
import java.util.zip.ZipOutputStream;

/**
 * Runs the Kotlin compilers (JVM, Native, JS/Wasm) in-process for Bazel, either once from a flag
 * file or as a persistent worker.
 *
 * <p>Multiplatform source sets are passed as fragments ({@code --fragment}, {@code --refines},
 * {@code --src fragment=path}) and turned into the compiler's -Xfragment* arguments here, so that
 * sources extracted from generated srcjars can be assigned to fragments too.
 */
public final class KotlinBuilder {
  /** Fixed entry time so jars are byte-for-byte reproducible regardless of host clock or zone. */
  private static final LocalDateTime ZIP_TIME = LocalDateTime.of(2010, 1, 1, 0, 0, 0);

  private static final Map<String, ClassLoader> LOADERS = new HashMap<>();

  public static void main(String[] args) throws Exception {
    if (Arrays.asList(args).contains("--persistent_worker")) {
      WorkerProtocol.serve(KotlinBuilder::run);
      return;
    }
    List<String> expanded = WorkerProtocol.expandFlagFiles(Arrays.asList(args));
    ByteArrayOutputStream out = new ByteArrayOutputStream();
    int code;
    try (PrintStream ps = new PrintStream(out, true, StandardCharsets.UTF_8)) {
      code = run(expanded, ps);
    }
    System.err.print(out.toString(StandardCharsets.UTF_8));
    System.exit(code);
  }

  /** Options shared by every compile mode. Everything after "--" is passed to the compiler. */
  private static final class Options {
    String mode;
    String compilerMain;
    List<String> compilerClasspath = new ArrayList<>();
    String output;
    String abiOutput;
    String cacheHost;
    String abiPlugin;
    String sourceJarOutput;
    String resourcesOutput;
    String tmpDir;
    List<String> fragments = new ArrayList<>();
    List<String> refines = new ArrayList<>();
    Map<String, List<String>> sources = new LinkedHashMap<>();
    Map<String, List<String>> srcjars = new LinkedHashMap<>();
    List<String[]> resources = new ArrayList<>();
    List<String> resourceJars = new ArrayList<>();
    List<String> javacArgs = new ArrayList<>();
    List<String> javaSources = new ArrayList<>();
    List<String> compilerArgs = new ArrayList<>();
    Map<String, String> sysProps = new LinkedHashMap<>();
    boolean packKlib;
    List<String> cacheKlibs = new ArrayList<>();
    List<String> cacheDirs = new ArrayList<>();
  }

  private static Options parse(List<String> args) {
    Options o = new Options();
    int i = 0;
    while (i < args.size()) {
      String a = args.get(i);
      if (a.equals("--")) {
        o.compilerArgs.addAll(args.subList(i + 1, args.size()));
        break;
      }
      String v = i + 1 < args.size() ? args.get(i + 1) : null;
      switch (a) {
        case "--mode": o.mode = v; break;
        case "--compiler_main": o.compilerMain = v; break;
        case "--compiler_classpath": o.compilerClasspath.add(v); break;
        case "--output": o.output = v; break;
        case "--abi_output": o.abiOutput = v; break;
        case "--cache_host": o.cacheHost = v; break;
        case "--abi_plugin": o.abiPlugin = v; break;
        case "--source_jar_output": o.sourceJarOutput = v; break;
        case "--resources_output": o.resourcesOutput = v; break;
        case "--tmp_dir": o.tmpDir = v; break;
        case "--fragment": o.fragments.add(v); break;
        case "--refines": o.refines.add(v); break;
        case "--src": {
          int eq = v.indexOf('=');
          o.sources.computeIfAbsent(v.substring(0, eq), k -> new ArrayList<>()).add(v.substring(eq + 1));
          break;
        }
        case "--srcjar": {
          int eq = v.indexOf('=');
          o.srcjars.computeIfAbsent(v.substring(0, eq), k -> new ArrayList<>()).add(v.substring(eq + 1));
          break;
        }
        case "--resource": {
          int eq = v.indexOf('=');
          o.resources.add(new String[] {v.substring(0, eq), v.substring(eq + 1)});
          break;
        }
        case "--resource_jar": o.resourceJars.add(v); break;
        case "--java_src": o.javaSources.add(v); break;
        case "--javac_arg": o.javacArgs.add(v); break;
        case "--sysprop": {
          int eq = v.indexOf('=');
          o.sysProps.put(v.substring(0, eq), v.substring(eq + 1));
          break;
        }
        case "--pack_klib": o.packKlib = true; i += 1; continue;
        case "--cache_klib": o.cacheKlibs.add(v); break;
        case "--cache_dir": o.cacheDirs.add(v); break;
        default:
          throw new IllegalArgumentException("Unknown builder flag: " + a);
      }
      i += 2;
    }
    return o;
  }

  static int run(List<String> args, PrintStream out) throws Exception {
    Options o = parse(args);
    Path tmp = Paths.get(o.tmpDir);
    deleteRecursively(tmp);
    Files.createDirectories(tmp);
    try {
      switch (o.mode) {
        case "jvm": return compileJvm(o, tmp, out);
        case "klib": return compileKlib(o, tmp, out);
        case "raw": return invoke(o, withCachedLibraries(o, o.compilerArgs), out);
        case "native_cache": return buildNativeCaches(o, out);
        default: throw new IllegalArgumentException("Unknown mode " + o.mode);
      }
    } finally {
      deleteRecursively(tmp);
    }
  }

  /** Builds the source list and -Xfragment* arguments, extracting srcjars into {@code tmp}. */
  private static List<String> sourceArgs(Options o, Path tmp, List<String> javaOut) throws IOException {
    Map<String, List<String>> byFragment = new LinkedHashMap<>();
    for (String f : o.fragments) {
      byFragment.put(f, new ArrayList<>());
    }
    for (Map.Entry<String, List<String>> e : o.sources.entrySet()) {
      byFragment.computeIfAbsent(e.getKey(), k -> new ArrayList<>()).addAll(e.getValue());
    }
    int n = 0;
    for (Map.Entry<String, List<String>> e : o.srcjars.entrySet()) {
      for (String jar : e.getValue()) {
        Path dest = tmp.resolve("srcjar" + (n++));
        for (Path p : unzip(Paths.get(jar), dest)) {
          String s = p.toString();
          if (s.endsWith(".kt")) {
            byFragment.computeIfAbsent(e.getKey(), k -> new ArrayList<>()).add(s);
          } else if (s.endsWith(".java")) {
            javaOut.add(s);
          }
        }
      }
    }
    for (String j : o.javaSources) {
      javaOut.add(j);
    }
    List<String> result = new ArrayList<>();
    // Every source set is a fragment; plain JVM modules use the single fragment "main".
    boolean multiplatform = !(byFragment.size() == 1 && byFragment.containsKey("main"));
    if (multiplatform) {
      result.add("-Xmulti-platform");
      result.add("-Xfragments=" + String.join(",", byFragment.keySet()));
      if (!o.refines.isEmpty()) {
        result.add("-Xfragment-refines=" + String.join(",", o.refines));
      }
      List<String> fs = new ArrayList<>();
      for (Map.Entry<String, List<String>> e : byFragment.entrySet()) {
        for (String s : e.getValue()) {
          fs.add(e.getKey() + ":" + s);
        }
      }
      if (!fs.isEmpty()) {
        result.add("-Xfragment-sources=" + String.join(",", fs));
      }
    }
    for (List<String> srcs : byFragment.values()) {
      result.addAll(srcs);
    }
    result.addAll(javaOut);
    return result;
  }

  private static boolean hasKotlinSources(List<String> srcArgs) {
    for (String s : srcArgs) {
      if (s.endsWith(".kt")) {
        return true;
      }
    }
    return false;
  }

  private static int compileJvm(Options o, Path tmp, PrintStream out) throws Exception {
    Path classes = tmp.resolve("classes");
    Path abiClasses = tmp.resolve("abi");
    Files.createDirectories(classes);
    List<String> javaSrcs = new ArrayList<>();
    List<String> srcArgs = sourceArgs(o, tmp, javaSrcs);
    List<String> classpath = new ArrayList<>();
    for (int i = 0; i < o.compilerArgs.size(); i++) {
      if (o.compilerArgs.get(i).equals("-classpath") || o.compilerArgs.get(i).equals("-cp")) {
        classpath.addAll(Arrays.asList(o.compilerArgs.get(i + 1).split(File.pathSeparator)));
      }
    }
    if (hasKotlinSources(srcArgs)) {
      List<String> args = new ArrayList<>(o.compilerArgs);
      args.add("-d");
      args.add(classes.toString());
      if (o.abiOutput != null) {
        Files.createDirectories(abiClasses);
        args.add("-Xplugin=" + o.abiPlugin);
        args.add("-P");
        args.add("plugin:org.jetbrains.kotlin.jvm.abi:outputDir=" + abiClasses);
      }
      args.addAll(srcArgs);
      int code = invoke(o, args, out);
      if (code != 0) {
        return code;
      }
    }
    if (!javaSrcs.isEmpty()) {
      int code = compileJava(o, javaSrcs, classpath, classes, out);
      if (code != 0) {
        return code;
      }
      if (o.abiOutput != null) {
        // jvm-abi-gen only sees Kotlin classes; ship the javac output whole in the ABI jar.
        copyTree(classes, abiClasses, p -> p.toString().endsWith(".class"));
      }
    }
    Map<String, Path> resources = new TreeMap<>();
    for (String[] r : o.resources) {
      resources.put(r[1], Paths.get(r[0]));
    }
    if (o.resourcesOutput != null) {
      writeJar(Paths.get(o.output), classes, new TreeMap<>(), List.of());
      writeJar(Paths.get(o.resourcesOutput), null, resources, o.resourceJars);
    } else {
      writeJar(Paths.get(o.output), classes, resources, o.resourceJars);
    }
    if (o.abiOutput != null) {
      writeJar(Paths.get(o.abiOutput), abiClasses, new TreeMap<>(), List.of());
    }
    if (o.sourceJarOutput != null) {
      Map<String, Path> srcs = new TreeMap<>();
      for (List<String> l : o.sources.values()) {
        for (String s : l) {
          srcs.put(stripToPackageRoot(Paths.get(s)), Paths.get(s));
        }
      }
      writeJar(Paths.get(o.sourceJarOutput), null, srcs, List.of());
    }
    return 0;
  }

  private static int compileJava(Options o, List<String> javaSrcs, List<String> classpath, Path classes, PrintStream out)
      throws IOException {
    javax.tools.JavaCompiler javac = javax.tools.ToolProvider.getSystemJavaCompiler();
    List<String> args = new ArrayList<>(o.javacArgs);
    List<String> cp = new ArrayList<>(classpath);
    cp.add(0, classes.toString());
    args.add("-classpath");
    args.add(String.join(File.pathSeparator, cp));
    args.add("-d");
    args.add(classes.toString());
    args.add("-implicit:none");
    args.add("-proc:none");
    args.addAll(javaSrcs);
    ByteArrayOutputStream err = new ByteArrayOutputStream();
    int code = javac.run(null, err, err, args.toArray(new String[0]));
    out.print(err.toString(StandardCharsets.UTF_8));
    return code;
  }

  private static int compileKlib(Options o, Path tmp, PrintStream out) throws Exception {
    List<String> srcArgs = sourceArgs(o, tmp, new ArrayList<>());
    List<String> args = new ArrayList<>(o.compilerArgs);
    args.addAll(srcArgs);
    return invoke(o, args, out);
  }

  private static synchronized ClassLoader loaderFor(List<String> classpath) throws IOException {
    String key = String.join(File.pathSeparator, classpath);
    ClassLoader cl = LOADERS.get(key);
    if (cl == null) {
      URL[] urls = new URL[classpath.size()];
      for (int i = 0; i < urls.length; i++) {
        urls[i] = new File(classpath.get(i)).getAbsoluteFile().toURI().toURL();
      }
      cl = new URLClassLoader(urls, ClassLoader.getPlatformClassLoader());
      LOADERS.put(key, cl);
    }
    return cl;
  }

  private static int invoke(Options o, List<String> rawArgs, PrintStream out) throws Exception {
    // The exec root differs per sandbox and worker; flags that strip it from outputs (klib source
    // paths, native debug info) name it with this token.
    String execRoot = Paths.get("").toAbsolutePath().toString();
    boolean nativeCompiler = o.compilerMain.equals("org.jetbrains.kotlin.cli.bc.K2Native");
    List<String> args = new ArrayList<>(rawArgs.size());
    for (String a : rawArgs) {
      String arg = a.replace("__EXECROOT__", execRoot);
      args.add(nativeCompiler ? absoluteLibraryReference(arg, execRoot) : arg);
    }
    for (Map.Entry<String, String> e : o.sysProps.entrySet()) {
      String value = e.getValue();
      if (value.startsWith("abs:")) {
        value = Paths.get(value.substring(4)).toAbsolutePath().toString();
      }
      System.setProperty(e.getKey(), value);
    }
    ClassLoader cl = loaderFor(o.compilerClasspath);
    Thread current = Thread.currentThread();
    ClassLoader previous = current.getContextClassLoader();
    current.setContextClassLoader(cl);
    try {
      Class<?> compilerClass = Class.forName(o.compilerMain, true, cl);
      Object compiler = compilerClass.getDeclaredConstructor().newInstance();
      Method exec = compilerClass.getMethod("exec", PrintStream.class, String[].class);
      Object exitCode = exec.invoke(compiler, out, (Object) args.toArray(new String[0]));
      String name = exitCode.toString();
      return name.equals("OK") ? 0 : (name.equals("COMPILATION_ERROR") ? 1 : 2);
    } finally {
      current.setContextClassLoader(previous);
    }
  }

  /**
   * Kotlin/Native looks up the klib named by these flags among the resolved libraries by exact path,
   * and it resolves a relative {@code -library} against the working directory.
   */
  private static String absoluteLibraryReference(String arg, String execRoot) {
    for (String flag : new String[] {"-Xinclude=", "-Xadd-cache=", "-Xcached-library="}) {
      if (arg.startsWith(flag) && arg.charAt(flag.length()) != '/') {
        return flag + execRoot + "/" + arg.substring(flag.length());
      }
    }
    return arg;
  }

  /**
   * Kotlin/Native static caches of {@code --cache_klib} libraries, built into {@code --output} in
   * dependency order, so a library of the same target can use the caches built before it.
   */
  private static int buildNativeCaches(Options o, PrintStream out) throws Exception {
    Path output = Paths.get(o.output);
    Files.createDirectories(output);
    Map<String, String> byName = new LinkedHashMap<>();
    Map<String, List<String>> depends = new HashMap<>();
    for (String klib : o.cacheKlibs) {
      Properties m = klibManifest(klib);
      String name = m.getProperty("unique_name");
      byName.put(name, klib);
      depends.put(name, Arrays.asList(m.getProperty("depends", "").trim().split("\\s+")));
    }
    // The compiler stubs out what it cannot resolve, so a missing dependency would give a cache
    // without the library's code instead of an error.
    Set<String> available = new LinkedHashSet<>(byName.keySet());
    for (int i = 0; i + 1 < o.compilerArgs.size(); i++) {
      if (o.compilerArgs.get(i).equals("-library")) {
        available.add(klibManifest(o.compilerArgs.get(i + 1)).getProperty("unique_name"));
      }
    }
    for (Map.Entry<String, List<String>> e : depends.entrySet()) {
      for (String d : e.getValue()) {
        if (!d.isEmpty() && !available.contains(d) && !d.equals("stdlib")
            && !d.startsWith("org.jetbrains.kotlin.native.platform.")) {
          out.println("error: cannot cache " + e.getKey() + ": its dependency " + d
              + " is not among the libraries it was built with");
          return 1;
        }
      }
    }
    List<String> order = new ArrayList<>();
    for (String name : byName.keySet()) {
      visit(name, depends, byName.keySet(), new LinkedHashSet<>(), order);
    }
    for (String name : order) {
      List<String> args = new ArrayList<>();
      args.add("-Xcache-directory=" + output);
      args.add("-Xadd-cache=" + byName.get(name));
      args.addAll(o.compilerArgs);
      for (String done : order.subList(0, order.indexOf(name))) {
        args.add("-library");
        args.add(byName.get(done));
      }
      Options withOwn = new Options();
      withOwn.cacheDirs.addAll(o.cacheDirs);
      withOwn.cacheDirs.add(o.output);
      int code = invoke(o, withCachedLibraries(withOwn, args), out);
      if (code != 0) {
        return code;
      }
    }
    normalizeArchiveModes(output);
    if (o.cacheHost != null) {
      setCacheHost(output, o.cacheHost);
    }
    if (o.abiOutput != null) {
      writeCacheAbi(output, Paths.get(o.abiOutput));
    }
    return 0;
  }

  /**
   * Records {@code host} as the host of every cache under {@code caches}: the compiler writes the
   * one it runs on but never reads it, and caches from different hosts are otherwise the same.
   */
  private static void setCacheHost(Path caches, String host) throws IOException {
    try (var entries = Files.list(caches)) {
      for (Path cache : entries.sorted().toList()) {
        Path metadata = cache.resolve("metadata.properties");
        if (!Files.isRegularFile(metadata)) {
          continue;
        }
        List<String> lines = new ArrayList<>();
        for (String line : Files.readAllLines(metadata, StandardCharsets.UTF_8)) {
          lines.add(line.startsWith("host=") ? "host=" + host : line);
        }
        Files.write(metadata, lines, StandardCharsets.UTF_8);
      }
    }
  }

  /**
   * Gives every member of the static libraries under {@code caches} mode 644. {@code libtool -D}
   * zeroes their dates and owners but keeps the objects' modes, which follow the umask: 0 on
   * BuildBuddy's executors.
   */
  private static void normalizeArchiveModes(Path caches) throws IOException {
    List<Path> archives;
    try (var files = Files.walk(caches)) {
      archives = files.filter(p -> p.toString().endsWith(".a") && Files.isRegularFile(p)).sorted().toList();
    }
    byte[] mode = "100644  ".getBytes(StandardCharsets.US_ASCII);
    byte[] header = new byte[60];
    for (Path archive : archives) {
      try (RandomAccessFile f = new RandomAccessFile(archive.toFile(), "rw")) {
        if (f.length() < 8) {
          continue;
        }
        byte[] magic = new byte[8];
        f.readFully(magic);
        if (!new String(magic, StandardCharsets.US_ASCII).equals("!<arch>\n")) {
          continue;
        }
        // Each member: a 60-byte header (mode at 40, size at 48), its data, padded to an even size.
        for (long pos = 8; pos + header.length <= f.length(); ) {
          f.seek(pos);
          f.readFully(header);
          long size = Long.parseLong(new String(header, 48, 10, StandardCharsets.US_ASCII).trim());
          f.seek(pos + 40);
          f.write(mode);
          pos += header.length + size + (size % 2);
        }
      }
    }
  }

  /**
   * What building a dependent's cache reads from these caches: the ir/ metadata and bitcode_deps,
   * with empty files in place of the compiled code, whose names the compiler checks. It only
   * changes when something a dependent's code generation uses does.
   */
  private static void writeCacheAbi(Path caches, Path abi) throws IOException {
    Files.createDirectories(abi);
    try (var entries = Files.list(caches)) {
      for (Path cache : entries.sorted().toList()) {
        Path target = abi.resolve(cache.getFileName().toString());
        copyTree(cache.resolve("ir"), target.resolve("ir"), p -> true);
        Path bin = cache.resolve("bin");
        Files.createDirectories(target.resolve("bin"));
        try (var files = Files.list(bin)) {
          for (Path f : files.sorted().toList()) {
            Path to = target.resolve("bin").resolve(f.getFileName().toString());
            if (f.getFileName().toString().equals("bitcode_deps")) {
              Files.copy(f, to);
            } else {
              Files.createFile(to);
            }
          }
        }
      }
    }
  }

  private static void visit(String name, Map<String, List<String>> depends, Set<String> own, Set<String> seen, List<String> order) {
    if (!seen.add(name) || order.contains(name)) {
      return;
    }
    for (String d : depends.get(name)) {
      if (own.contains(d)) {
        visit(d, depends, own, seen, order);
      }
    }
    order.add(name);
  }

  /**
   * Adds {@code -Xcached-library=<klib>,<cache>} for every {@code -library} whose cache is in one of
   * the {@code --cache_dir} trees (a cache is {@code <unique name>-cache} there).
   */
  private static List<String> withCachedLibraries(Options o, List<String> args) throws IOException {
    if (o.cacheDirs.isEmpty()) {
      return args;
    }
    Map<String, Path> caches = new HashMap<>();
    for (String dir : o.cacheDirs) {
      Path d = Paths.get(dir);
      if (!Files.isDirectory(d)) {
        continue;
      }
      try (var entries = Files.list(d)) {
        entries.filter(p -> p.getFileName().toString().endsWith("-cache"))
            .forEach(p -> caches.put(p.getFileName().toString(), p));
      }
    }
    List<String> result = new ArrayList<>(args);
    for (int i = 0; i + 1 < args.size(); i++) {
      if (!args.get(i).equals("-library")) {
        continue;
      }
      String klib = args.get(i + 1);
      Path cache = caches.get(klibManifest(klib).getProperty("unique_name") + "-cache");
      if (cache != null) {
        result.add("-Xcached-library=" + klib + "," + cache);
      }
    }
    return result;
  }

  private static Properties klibManifest(String klib) throws IOException {
    Properties m = new Properties();
    Path p = Paths.get(klib);
    if (Files.isDirectory(p)) {
      try (InputStream in = Files.newInputStream(p.resolve("default/manifest"))) {
        m.load(in);
      }
      return m;
    }
    try (ZipFile zip = new ZipFile(p.toFile())) {
      Enumeration<? extends ZipEntry> entries = zip.entries();
      while (entries.hasMoreElements()) {
        ZipEntry e = entries.nextElement();
        if (e.getName().endsWith("default/manifest")) {
          try (InputStream in = zip.getInputStream(e)) {
            m.load(in);
          }
          return m;
        }
      }
    }
    throw new IOException("No manifest in " + klib);
  }

  private static String stripToPackageRoot(Path p) {
    String s = p.toString();
    for (String marker : new String[] {"/kotlin/", "/java/"}) {
      int idx = s.lastIndexOf(marker);
      if (idx >= 0) {
        return s.substring(idx + marker.length());
      }
    }
    return p.getFileName().toString();
  }

  private static List<Path> unzip(Path zip, Path dest) throws IOException {
    List<Path> files = new ArrayList<>();
    try (ZipFile zf = new ZipFile(zip.toFile())) {
      Enumeration<? extends ZipEntry> entries = zf.entries();
      while (entries.hasMoreElements()) {
        ZipEntry e = entries.nextElement();
        if (e.isDirectory()) {
          continue;
        }
        Path target = dest.resolve(e.getName()).normalize();
        if (!target.startsWith(dest)) {
          throw new IOException("Bad zip entry " + e.getName());
        }
        Files.createDirectories(target.getParent());
        try (InputStream is = zf.getInputStream(e)) {
          Files.copy(is, target, StandardCopyOption.REPLACE_EXISTING);
        }
        files.add(target);
      }
    }
    files.sort(null);
    return files;
  }

  interface PathFilter {
    boolean accept(Path p);
  }

  private static void copyTree(Path from, Path to, PathFilter filter) throws IOException {
    if (!Files.exists(from)) {
      return;
    }
    Files.walkFileTree(from, new SimpleFileVisitor<>() {
      @Override
      public FileVisitResult visitFile(Path file, BasicFileAttributes attrs) throws IOException {
        if (filter.accept(file)) {
          Path target = to.resolve(from.relativize(file).toString());
          if (!Files.exists(target)) {
            Files.createDirectories(target.getParent());
            Files.copy(file, target);
          }
        }
        return FileVisitResult.CONTINUE;
      }
    });
  }

  /** Writes a jar with sorted entries and fixed timestamps. */
  static void writeJar(Path jar, Path classesDir, Map<String, Path> extra, List<String> mergeJars) throws IOException {
    TreeMap<String, Object> entries = new TreeMap<>();
    if (classesDir != null && Files.exists(classesDir)) {
      Files.walkFileTree(classesDir, new SimpleFileVisitor<>() {
        @Override
        public FileVisitResult visitFile(Path file, BasicFileAttributes attrs) {
          entries.put(classesDir.relativize(file).toString().replace(File.separatorChar, '/'), file);
          return FileVisitResult.CONTINUE;
        }
      });
    }
    for (Map.Entry<String, Path> e : extra.entrySet()) {
      entries.put(e.getKey(), e.getValue());
    }
    for (String mj : mergeJars) {
      try (ZipFile zf = new ZipFile(mj)) {
        Enumeration<? extends ZipEntry> it = zf.entries();
        while (it.hasMoreElements()) {
          ZipEntry e = it.nextElement();
          if (!e.isDirectory() && !e.getName().equals("META-INF/MANIFEST.MF")) {
            try (InputStream is = zf.getInputStream(e)) {
              entries.putIfAbsent(e.getName(), is.readAllBytes());
            }
          }
        }
      }
    }
    entries.remove("META-INF/MANIFEST.MF");
    Set<String> dirs = new LinkedHashSet<>();
    for (String name : entries.keySet()) {
      int idx = name.lastIndexOf('/');
      while (idx > 0) {
        dirs.add(name.substring(0, idx + 1));
        idx = name.lastIndexOf('/', idx - 1);
      }
    }
    Files.createDirectories(jar.toAbsolutePath().getParent());
    try (OutputStream fos = Files.newOutputStream(jar); ZipOutputStream zos = new ZipOutputStream(fos)) {
      putEntry(zos, "META-INF/", null);
      putEntry(zos, "META-INF/MANIFEST.MF", "Manifest-Version: 1.0\r\nCreated-By: bazel\r\n\r\n".getBytes(StandardCharsets.UTF_8));
      for (String d : new java.util.TreeSet<>(dirs)) {
        if (!d.equals("META-INF/")) {
          putEntry(zos, d, null);
        }
      }
      for (Map.Entry<String, Object> e : entries.entrySet()) {
        Object v = e.getValue();
        byte[] data = v instanceof Path ? Files.readAllBytes((Path) v) : (byte[]) v;
        putEntry(zos, e.getKey(), data);
      }
    }
  }

  private static void putEntry(ZipOutputStream zos, String name, byte[] data) throws IOException {
    ZipEntry e = new ZipEntry(name);
    e.setTimeLocal(ZIP_TIME);
    zos.putNextEntry(e);
    if (data != null) {
      zos.write(data);
    }
    zos.closeEntry();
  }

  private static void deleteRecursively(Path p) throws IOException {
    if (!Files.exists(p)) {
      return;
    }
    Files.walkFileTree(p, new SimpleFileVisitor<>() {
      @Override
      public FileVisitResult visitFile(Path file, BasicFileAttributes attrs) throws IOException {
        Files.delete(file);
        return FileVisitResult.CONTINUE;
      }

      @Override
      public FileVisitResult postVisitDirectory(Path dir, IOException exc) throws IOException {
        Files.delete(dir);
        return FileVisitResult.CONTINUE;
      }
    });
  }
}
