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
import java.util.zip.ZipOutputStream;

/**
 * Runs KSP2 for one compilation: copies the declared sources into a private directory (KSP takes
 * source roots, not file lists), runs the KSP command line in a child JVM and zips the generated
 * sources and resources with fixed timestamps.
 */
public final class KspRunner {
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
    Path tmp = null;
    List<String> kspCp = new ArrayList<>();
    List<String> processorCp = new ArrayList<>();
    List<String[]> srcs = new ArrayList<>();
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
        case "--src": srcs.add(v.split("=", 2)); break;
        case "--arg": kspArgs.add(v); break;
        default: throw new IllegalArgumentException(k);
      }
    }
    deleteRecursively(tmp);
    Path main = tmp.resolve("src/main");
    Path common = tmp.resolve("src/common");
    Files.createDirectories(main);
    Files.createDirectories(common);
    for (String[] s : srcs) {
      Path root = s[0].equals("common") ? common : main;
      Path target = root.resolve(s[1]);
      Files.createDirectories(target.getParent());
      Files.copy(Paths.get(s[1]), target);
    }
    Path out = tmp.resolve("out");
    List<String> cmd = new ArrayList<>();
    cmd.add(Paths.get(System.getProperty("java.home"), "bin", "java").toString());
    cmd.add("-Xmx3g");
    cmd.add("-Djava.awt.headless=true");
    cmd.add("-cp");
    cmd.add(String.join(File.pathSeparator, kspCp));
    cmd.add(mainClass);
    cmd.add("-source-roots=" + main + File.pathSeparator + common);
    cmd.add("-common-source-roots=" + common);
    cmd.add("-project-base-dir=" + tmp);
    cmd.add("-output-base-dir=" + out);
    cmd.add("-caches-dir=" + tmp.resolve("caches"));
    cmd.add("-class-output-dir=" + out.resolve("classes"));
    cmd.add("-kotlin-output-dir=" + out.resolve("kotlin"));
    cmd.add("-java-output-dir=" + out.resolve("java"));
    cmd.add("-resource-output-dir=" + out.resolve("resources"));
    cmd.add("-incremental=false");
    if (mainClass.endsWith("KSPJvmMain")) {
      cmd.add("-jdk-home=" + System.getProperty("java.home"));
    }
    cmd.addAll(kspArgs);
    cmd.add(String.join(File.pathSeparator, processorCp));
    Process p = new ProcessBuilder(cmd).inheritIO().start();
    int code = p.waitFor();
    if (code != 0) {
      System.exit(code);
    }
    zip(Paths.get(outSrcjar), out.resolve("kotlin"), out.resolve("java"));
    zip(Paths.get(outResjar), out.resolve("resources"));
    deleteRecursively(tmp);
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
