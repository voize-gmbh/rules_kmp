package de.voize.bazel.ksp;

import java.io.File;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.nio.file.FileVisitResult;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.nio.file.SimpleFileVisitor;
import java.nio.file.attribute.BasicFileAttributes;
import java.time.LocalDateTime;
import java.util.ArrayList;
import java.util.List;
import java.util.TreeMap;
import java.util.zip.ZipEntry;
import java.util.zip.ZipFile;
import java.util.zip.ZipOutputStream;

/**
 * Runs KSP2 for one compilation: copies the declared sources and those of the srcjars into a
 * private directory, runs the KSP command line in a child JVM and zips the generated sources and
 * resources with fixed timestamps.
 */
public final class KspRunner {
  /**
   * Runs a KSP main class with the arguments in a file, one per line, and exits: KSP leaves
   * non-daemon threads behind, which would keep the child JVM alive after a failure in some modes.
   * The file keeps long library lists off the command line, which the OS limits.
   */
  public static final class ExitingMain {
    public static void main(String[] args) {
      try {
        String[] kspArgs = Files.readAllLines(Paths.get(args[1])).toArray(new String[0]);
        Class.forName(args[0])
            .getMethod("main", String[].class)
            .invoke(null, (Object) kspArgs);
      } catch (java.lang.reflect.InvocationTargetException e) {
        e.getCause().printStackTrace();
        System.exit(1);
      } catch (ReflectiveOperationException | IOException e) {
        e.printStackTrace();
        System.exit(1);
      }
      System.exit(0);
    }
  }

  private static final LocalDateTime ZIP_TIME = LocalDateTime.of(2010, 1, 1, 0, 0, 0);

  public static void main(String[] argv) throws Exception {
    List<String> args = new ArrayList<>();
    for (String a : argv) {
      if (a.startsWith("@")) {
        for (String l : Files.readAllLines(Paths.get(a.substring(1)))) {
          if (!l.isEmpty()) {
            args.add(l);
          }
        }
      } else {
        args.add(a);
      }
    }
    String mainClass = null;
    String outSrcjar = null;
    String outResjar = null;
    boolean noSources = false;
    Path tmp = null;
    List<String> kspCp = new ArrayList<>();
    List<String> processorCp = new ArrayList<>();
    // {"src" or "srcjar", "main" or "common", path}, in command line order.
    List<String[]> inputs = new ArrayList<>();
    List<String> kspArgs = new ArrayList<>();
    for (int i = 0; i < args.size(); i += 2) {
      String k = args.get(i);
      String v = args.get(i + 1);
      switch (k) {
        case "--main": mainClass = v; break;
        case "--out_srcjar": outSrcjar = v; break;
        case "--out_resjar": outResjar = v; break;
        case "--tmp": tmp = Paths.get(v).toAbsolutePath(); break;
        case "--ksp_cp": kspCp.add(v); break;
        case "--processor_cp": processorCp.add(v); break;
        case "--src":
        case "--srcjar":
          String[] rootAndPath = v.split("=", 2);
          inputs.add(new String[] {k.substring(2), rootAndPath[0], rootAndPath[1]});
          break;
        case "--no_sources": noSources = Boolean.parseBoolean(v); break;
        case "--arg": kspArgs.add(v); break;
        default: throw new IllegalArgumentException(k);
      }
    }
    deleteRecursively(tmp);
    Path main = tmp.resolve("src/main");
    Path common = tmp.resolve("src/common");
    Files.createDirectories(main);
    Files.createDirectories(common);
    // Each file is a source root of its own, in command line order: KSP processes files in the
    // order it finds them, which for a directory would be the file system's.
    List<String> mainFiles = new ArrayList<>();
    List<String> commonFiles = new ArrayList<>();
    for (int i = 0; i < inputs.size(); i++) {
      String[] in = inputs.get(i);
      boolean isCommon = in[1].equals("common");
      Path root = isCommon ? common : main;
      List<Path> written = new ArrayList<>();
      if (in[0].equals("src")) {
        Path target = root.resolve(in[2]);
        Files.createDirectories(target.getParent());
        Files.copy(Paths.get(in[2]), target);
        written.add(target);
      } else {
        extractSources(Paths.get(in[2]), root.resolve("srcjar" + i), written);
      }
      for (Path w : written) {
        (isCommon ? commonFiles : mainFiles).add(w.toString());
      }
    }
    List<String> allFiles = new ArrayList<>(commonFiles);
    allFiles.addAll(mainFiles);
    Path out = tmp.resolve("out");
    List<String> cmd = new ArrayList<>();
    cmd.add(Paths.get(System.getProperty("java.home"), "bin", "java").toString());
    cmd.add("-Xmx3g");
    cmd.add("-Djava.awt.headless=true");
    List<String> childCp = new ArrayList<>(kspCp);
    childCp.add(Paths.get(KspRunner.class.getProtectionDomain().getCodeSource().getLocation().toURI()).toString());
    cmd.add("-cp");
    cmd.add(String.join(File.pathSeparator, childCp));
    cmd.add(ExitingMain.class.getName());
    cmd.add(mainClass);
    List<String> kspCmd = new ArrayList<>();
    kspCmd.add("-source-roots=" + String.join(File.pathSeparator, allFiles));
    kspCmd.add("-common-source-roots=" + String.join(File.pathSeparator, commonFiles));
    kspCmd.add("-project-base-dir=" + tmp);
    kspCmd.add("-output-base-dir=" + out);
    kspCmd.add("-caches-dir=" + tmp.resolve("caches"));
    kspCmd.add("-class-output-dir=" + out.resolve("classes"));
    kspCmd.add("-kotlin-output-dir=" + out.resolve("kotlin"));
    kspCmd.add("-resource-output-dir=" + out.resolve("resources"));
    kspCmd.add("-incremental=false");
    // Only the JVM command line knows these; the others take an unknown flag for the processor path.
    if (mainClass.endsWith("KSPJvmMain")) {
      kspCmd.add("-java-output-dir=" + out.resolve("java"));
      kspCmd.add("-jdk-home=" + System.getProperty("java.home"));
    }
    kspCmd.addAll(kspArgs);
    kspCmd.add(String.join(File.pathSeparator, processorCp));
    Path argsFile = tmp.resolve("ksp-args.txt");
    Files.write(argsFile, kspCmd);
    cmd.add(argsFile.toString());
    Process p = new ProcessBuilder(cmd).inheritIO().start();
    int code = p.waitFor();
    if (code != 0) {
      System.exit(code);
    }
    if (noSources && (hasFiles(out.resolve("kotlin")) || hasFiles(out.resolve("java")))) {
      System.err.println("The KSP processors generated code, which this run is not compiled into: " + out);
      System.exit(1);
    }
    zip(Paths.get(outSrcjar), out.resolve("kotlin"), out.resolve("java"));
    zip(Paths.get(outResjar), out.resolve("resources"));
    deleteRecursively(tmp);
  }

  private static boolean hasFiles(Path dir) throws IOException {
    if (!Files.exists(dir)) {
      return false;
    }
    try (var files = Files.walk(dir)) {
      return files.anyMatch(Files::isRegularFile);
    }
  }

  private static void extractSources(Path jar, Path root, List<Path> written) throws IOException {
    try (ZipFile zf = new ZipFile(jar.toFile())) {
      List<? extends ZipEntry> entries = java.util.Collections.list(zf.entries());
      entries.sort(java.util.Comparator.comparing(ZipEntry::getName));
      for (var e : entries) {
        String name = e.getName();
        if (e.isDirectory() || !(name.endsWith(".kt") || name.endsWith(".java"))) {
          continue;
        }
        Path target = root.resolve(name).normalize();
        if (!target.startsWith(root)) {
          throw new IOException("Entry outside the source root: " + name);
        }
        Files.createDirectories(target.getParent());
        try (InputStream is = zf.getInputStream(e)) {
          Files.copy(is, target);
        }
        written.add(target);
      }
    }
  }

  private static void zip(Path zip, Path... dirs) throws IOException {
    TreeMap<String, Path> entries = new TreeMap<>();
    for (Path dir : dirs) {
      if (!Files.exists(dir)) {
        continue;
      }
      Files.walkFileTree(dir, new SimpleFileVisitor<>() {
        @Override
        public FileVisitResult visitFile(Path file, BasicFileAttributes attrs) {
          entries.put(dir.relativize(file).toString().replace(File.separatorChar, '/'), file);
          return FileVisitResult.CONTINUE;
        }
      });
    }
    try (OutputStream os = Files.newOutputStream(zip); ZipOutputStream zos = new ZipOutputStream(os)) {
      for (var e : entries.entrySet()) {
        ZipEntry ze = new ZipEntry(e.getKey());
        ze.setTimeLocal(ZIP_TIME);
        zos.putNextEntry(ze);
        try (InputStream is = Files.newInputStream(e.getValue())) {
          is.transferTo(zos);
        }
        zos.closeEntry();
      }
    }
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
