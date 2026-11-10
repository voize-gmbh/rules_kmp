package de.voize.bazel.kotlin;

import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.io.PrintStream;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Enumeration;
import java.util.HashMap;
import java.util.HashSet;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.regex.Matcher;
import java.util.regex.Pattern;
import java.util.zip.ZipEntry;
import java.util.zip.ZipFile;
import java.util.zip.ZipOutputStream;
import kotlin.Metadata;
import kotlin.metadata.Attributes;
import kotlin.metadata.KmFunction;
import kotlin.metadata.KmPackage;
import kotlin.metadata.KmProperty;
import kotlin.metadata.jvm.JvmExtensionsKt;
import kotlin.metadata.jvm.JvmFieldSignature;
import kotlin.metadata.jvm.JvmMetadataUtil;
import kotlin.metadata.jvm.JvmMethodSignature;
import kotlin.metadata.jvm.KmPackageParts;
import kotlin.metadata.jvm.KotlinClassMetadata;
import kotlin.metadata.jvm.KotlinModuleMetadata;
import org.jetbrains.org.objectweb.asm.AnnotationVisitor;
import org.jetbrains.org.objectweb.asm.ClassReader;
import org.jetbrains.org.objectweb.asm.ClassVisitor;
import org.jetbrains.org.objectweb.asm.ClassWriter;
import org.jetbrains.org.objectweb.asm.FieldVisitor;
import org.jetbrains.org.objectweb.asm.MethodVisitor;
import org.jetbrains.org.objectweb.asm.Opcodes;
import org.jetbrains.org.objectweb.asm.tree.AbstractInsnNode;
import org.jetbrains.org.objectweb.asm.tree.AnnotationNode;
import org.jetbrains.org.objectweb.asm.tree.ClassNode;
import org.jetbrains.org.objectweb.asm.tree.FieldInsnNode;
import org.jetbrains.org.objectweb.asm.tree.FieldNode;
import org.jetbrains.org.objectweb.asm.tree.MethodInsnNode;
import org.jetbrains.org.objectweb.asm.tree.MethodNode;
import org.jetbrains.org.objectweb.asm.tree.TypeInsnNode;

/**
 * Writes a Kotlin compilation's dependency ABI jars without the top-level functions and properties
 * its sources never name, so that adding one to a dependency leaves the compilation's inputs as
 * they were and Bazel reuses its outputs.
 *
 * <p>Resolution finds a top-level declaration by its name, which therefore appears in the sources,
 * except for operator conventions ({@code plus}, {@code getValue}, {@code invoke}...), which need the
 * {@code operator} modifier and are always kept. Java sources name the JVM names, which are matched
 * too. Inlining copies the bytecode of kept inline functions, so whatever that bytecode calls in a
 * file facade is kept as well. Classes, type aliases and everything that is not a file facade are
 * copied unchanged: a class's members can be reached without being named (supertypes, SAM
 * conversions, compiler plugins). The exceptions are the classes declared inside a dropped
 * function, which only inlining it would read, and a facade's source map once nothing in it can be
 * inlined: both record where the file ends, so a line added anywhere would change them. Each facade
 * is rewritten from what it keeps alone, so the output only changes when something kept does.
 */
public final class ClasspathFilter {
  private static final Pattern IDENTIFIER = Pattern.compile("`([^`\\r\\n]+)`|[\\p{L}\\p{N}_$]+");
  private static final int FILE_FACADE = 2;
  private static final String METADATA = "Lkotlin/Metadata;";
  private static final long ZIP_TIME = 1262304000000L; // 2010-01-01, as KotlinBuilder's jars

  public static void main(String[] args) throws Exception {
    if (Arrays.asList(args).contains("--persistent_worker")) {
      WorkerProtocol.serve(ClasspathFilter::run);
      return;
    }
    ByteArrayOutputStream out = new ByteArrayOutputStream();
    int code;
    try (PrintStream ps = new PrintStream(out, true, StandardCharsets.UTF_8)) {
      code = run(WorkerProtocol.expandFlagFiles(Arrays.asList(args)), ps);
    }
    System.err.print(out.toString(StandardCharsets.UTF_8));
    System.exit(code);
  }

  static int run(List<String> args, PrintStream out) throws IOException {
    List<String> sources = new ArrayList<>();
    List<String> srcjars = new ArrayList<>();
    Map<String, String> jars = new LinkedHashMap<>();
    for (int i = 0; i + 1 < args.size(); i += 2) {
      String v = args.get(i + 1);
      switch (args.get(i)) {
        case "--src" -> sources.add(v);
        case "--srcjar" -> srcjars.add(v);
        case "--jar" -> {
          int eq = v.indexOf('=');
          jars.put(v.substring(0, eq), v.substring(eq + 1));
        }
        default -> throw new IllegalArgumentException("Unknown flag: " + args.get(i));
      }
    }
    filter(names(sources, srcjars), jars);
    return 0;
  }

  /** Every identifier in the sources, including comments and strings, which only keeps more. */
  static Set<String> names(List<String> sources, List<String> srcjars) throws IOException {
    Set<String> names = new HashSet<>();
    for (String s : sources) {
      addNames(new String(Files.readAllBytes(Paths.get(s)), StandardCharsets.UTF_8), names);
    }
    for (String jar : srcjars) {
      try (ZipFile zip = new ZipFile(jar)) {
        Enumeration<? extends ZipEntry> entries = zip.entries();
        while (entries.hasMoreElements()) {
          ZipEntry e = entries.nextElement();
          if (e.getName().endsWith(".kt") || e.getName().endsWith(".java")) {
            try (InputStream in = zip.getInputStream(e)) {
              addNames(new String(in.readAllBytes(), StandardCharsets.UTF_8), names);
            }
          }
        }
      }
    }
    return names;
  }

  private static void addNames(String text, Set<String> names) {
    Matcher m = IDENTIFIER.matcher(text);
    while (m.find()) {
      names.add(m.group(1) != null ? m.group(1) : m.group());
    }
  }

  /** Writes each jar of {@code jars} (input path to output path) filtered for {@code names}. */
  static void filter(Set<String> names, Map<String, String> jars) throws IOException {
    Map<String, List<Entry>> contents = new LinkedHashMap<>();
    Map<String, List<Facade>> facades = new HashMap<>();
    for (String jar : jars.keySet()) {
      List<Entry> entries = read(jar);
      contents.put(jar, entries);
      for (Entry e : entries) {
        if (e.facade != null) {
          facades.computeIfAbsent(e.facade.node.name, k -> new ArrayList<>()).add(e.facade);
        }
      }
    }
    List<Facade> all = new ArrayList<>();
    facades.values().forEach(all::addAll);
    for (Facade f : all) {
      f.keepNamed(names);
    }
    // What kept inline bytecode calls in a facade stays, until nothing new is kept.
    boolean changed = true;
    while (changed) {
      changed = false;
      for (Facade f : all) {
        for (String[] ref : f.references()) {
          for (Facade target : facades.getOrDefault(ref[0], List.of())) {
            changed |= target.keepJvmName(ref[1]);
          }
        }
      }
    }
    Set<String> dropped = droppedLocalClasses(contents, facades, all);
    for (Facade f : all) {
      f.droppedLocalClasses = dropped;
    }
    for (Map.Entry<String, String> j : jars.entrySet()) {
      write(Paths.get(j.getValue()), contents.get(j.getKey()), dropped);
    }
  }

  /**
   * The classes declared inside facade methods that are left out (the lambdas and objects of
   * inline functions, kept in ABI jars for inlining), and the classes declared inside those.
   */
  private static Set<String> droppedLocalClasses(Map<String, List<Entry>> contents, Map<String, List<Facade>> facades, List<Facade> all) {
    Set<String> referenced = new HashSet<>();
    for (Facade f : all) {
      referenced.addAll(f.referencedClasses());
    }
    Set<String> dropped = new HashSet<>();
    boolean changed = true;
    while (changed) {
      changed = false;
      for (List<Entry> entries : contents.values()) {
        for (Entry e : entries) {
          Local local = e.local;
          if (local == null || dropped.contains(local.name()) || referenced.contains(local.name())) {
            continue;
          }
          boolean outerDropped = dropped.contains(local.outerClass());
          if (!outerDropped && local.outerMethod() != null) {
            for (Facade f : facades.getOrDefault(local.outerClass(), List.of())) {
              outerDropped |= !f.keepsMethod(local.outerMethod(), local.outerMethodDesc());
            }
          }
          if (outerDropped) {
            changed |= dropped.add(local.name());
          }
        }
      }
    }
    return dropped;
  }

  /** A class declared inside a method or class of a file facade. */
  private record Local(String name, String outerClass, String outerMethod, String outerMethodDesc) {}

  private record Entry(RawJar.Entry raw, Facade facade, Local local) {}

  /**
   * The jar's entries, with the file facades its .kotlin_module files list parsed. Only those are
   * inflated; the rest are copied as they are.
   */
  private static List<Entry> read(String jar) throws IOException {
    List<RawJar.Entry> raw;
    try {
      raw = RawJar.read(Paths.get(jar));
    } catch (RawJar.UnsupportedJarException e) {
      raw = new ArrayList<>();
      try (ZipFile zip = new ZipFile(jar)) {
        Enumeration<? extends ZipEntry> it = zip.entries();
        while (it.hasMoreElements()) {
          ZipEntry e2 = it.nextElement();
          try (InputStream in = zip.getInputStream(e2)) {
            raw.add(RawJar.Entry.stored(e2.getName(), in.readAllBytes()));
          }
        }
      }
    }
    Set<String> facadeEntries = new HashSet<>();
    for (RawJar.Entry e : raw) {
      if (e.name().startsWith("META-INF/") && e.name().endsWith(".kotlin_module")) {
        try {
          for (KmPackageParts parts : KotlinModuleMetadata.read(e.data()).getKmModule().getPackageParts().values()) {
            for (String facade : parts.getFileFacades()) {
              facadeEntries.add(facade + ".class");
            }
          }
        } catch (IllegalArgumentException unreadable) {
          // A newer metadata version: its facades stay as they are.
        }
      }
    }
    Set<String> facadePrefixes = new HashSet<>();
    for (String f : facadeEntries) {
      facadePrefixes.add(f.substring(0, f.length() - ".class".length()) + "$");
    }
    List<Entry> entries = new ArrayList<>(raw.size());
    for (RawJar.Entry e : raw) {
      if (facadeEntries.contains(e.name())) {
        entries.add(new Entry(e, Facade.of(e.data()), null));
      } else if (e.name().endsWith(".class") && facadePrefixes.stream().anyMatch(e.name()::startsWith)) {
        entries.add(new Entry(e, null, local(e.data())));
      } else {
        entries.add(new Entry(e, null, null));
      }
    }
    return entries;
  }

  private static Local local(byte[] bytes) {
    String[] outer = new String[4];
    new ClassReader(bytes).accept(new ClassVisitor(Opcodes.ASM9) {
      @Override
      public void visit(int version, int access, String name, String signature, String superName, String[] interfaces) {
        outer[0] = name;
      }

      @Override
      public void visitOuterClass(String owner, String name, String descriptor) {
        outer[1] = owner;
        outer[2] = name;
        outer[3] = descriptor;
      }

      @Override
      public void visitInnerClass(String name, String outerName, String innerName, int access) {
        if (name.equals(outer[0]) && outerName != null && outer[1] == null) {
          outer[1] = outerName;
        }
      }
    }, ClassReader.SKIP_CODE | ClassReader.SKIP_DEBUG | ClassReader.SKIP_FRAMES);
    return outer[1] == null ? null : new Local(outer[0], outer[1], outer[2], outer[3]);
  }

  private static void write(Path jar, List<Entry> entries, Set<String> dropped) throws IOException {
    List<RawJar.Entry> out = new ArrayList<>(entries.size());
    for (Entry e : entries) {
      if (e.local != null && dropped.contains(e.local.name())) {
        continue;
      }
      out.add(e.facade != null ? RawJar.Entry.stored(e.raw.name(), e.facade.write()) : e.raw);
    }
    try {
      RawJar.write(jar, out);
    } catch (RawJar.UnsupportedJarException tooLarge) {
      try (OutputStream fos = Files.newOutputStream(jar); ZipOutputStream zos = new ZipOutputStream(fos)) {
        for (RawJar.Entry e : out) {
          byte[] data = e.data();
          ZipEntry z = new ZipEntry(e.name());
          z.setMethod(ZipEntry.STORED);
          z.setTime(ZIP_TIME);
          z.setSize(data.length);
          z.setCrc(e.crc());
          zos.putNextEntry(z);
          zos.write(data);
          zos.closeEntry();
        }
      }
    }
  }

  /** A file facade class: the top-level functions, properties and type aliases of one file. */
  static final class Facade {
    final ClassNode node;
    final KotlinClassMetadata.FileFacade metadata;
    final List<KmFunction> functions;
    final List<KmProperty> properties;
    final Set<KmFunction> keptFunctions = new HashSet<>();
    final Set<KmProperty> keptProperties = new HashSet<>();
    Set<String> droppedLocalClasses = Set.of();

    private Facade(ClassNode node, KotlinClassMetadata.FileFacade metadata) {
      this.node = node;
      this.metadata = metadata;
      this.functions = new ArrayList<>(metadata.getKmPackage().getFunctions());
      this.properties = new ArrayList<>(metadata.getKmPackage().getProperties());
    }

    /** The facade in {@code bytes}, or null for any other class or one this can't rewrite. */
    static Facade of(byte[] bytes) {
      ClassReader reader = new ClassReader(bytes);
      AnnotationNode[] found = new AnnotationNode[1];
      reader.accept(new ClassVisitor(Opcodes.ASM9) {
        @Override
        public AnnotationVisitor visitAnnotation(String desc, boolean visible) {
          if (!desc.equals(METADATA)) {
            return null;
          }
          found[0] = new AnnotationNode(desc);
          return found[0];
        }

        @Override
        public FieldVisitor visitField(int access, String name, String desc, String signature, Object value) {
          return null;
        }

        @Override
        public MethodVisitor visitMethod(int access, String name, String desc, String signature, String[] exceptions) {
          return null;
        }
      }, ClassReader.SKIP_CODE | ClassReader.SKIP_DEBUG | ClassReader.SKIP_FRAMES);
      if (found[0] == null) {
        return null;
      }
      Map<String, Object> values = values(found[0]);
      if (!Integer.valueOf(FILE_FACADE).equals(values.get("k"))
          || !((String) values.getOrDefault("xs", "")).isEmpty()
          || !((String) values.getOrDefault("pn", "")).isEmpty()) {
        return null;
      }
      Metadata m = JvmMetadataUtil.Metadata(
          FILE_FACADE,
          ints(values.get("mv")),
          strings(values.get("d1")),
          strings(values.get("d2")),
          "",
          "",
          (Integer) values.getOrDefault("xi", 0));
      KotlinClassMetadata parsed;
      try {
        parsed = KotlinClassMetadata.readStrict(m);
      } catch (IllegalArgumentException e) {
        // Metadata newer than this reader: keep the class as it is.
        return null;
      }
      if (!(parsed instanceof KotlinClassMetadata.FileFacade f)) {
        return null;
      }
      ClassNode node = new ClassNode();
      reader.accept(node, 0);
      return new Facade(node, f);
    }

    void keepNamed(Set<String> names) {
      for (KmFunction f : functions) {
        JvmMethodSignature sig = JvmExtensionsKt.getSignature(f);
        if (names.contains(f.getName()) || (sig != null && names.contains(sig.getName())) || Attributes.isOperator(f)) {
          keptFunctions.add(f);
        }
      }
      for (KmProperty p : properties) {
        if (names.contains(p.getName())) {
          keptProperties.add(p);
          continue;
        }
        for (String jvmName : jvmNames(p)) {
          if (names.contains(jvmName)) {
            keptProperties.add(p);
            break;
          }
        }
      }
    }

    /** Keeps the declarations with JVM member {@code name}; returns whether that kept more. */
    boolean keepJvmName(String name) {
      boolean changed = false;
      for (KmFunction f : functions) {
        JvmMethodSignature sig = JvmExtensionsKt.getSignature(f);
        if (sig != null && (sig.getName().equals(name) || (sig.getName() + "$default").equals(name)
            || (sig.getName() + "$$forInline").equals(name))) {
          changed |= keptFunctions.add(f);
        }
      }
      for (KmProperty p : properties) {
        if (jvmNames(p).contains(name)) {
          changed |= keptProperties.add(p);
        }
      }
      return changed;
    }

    /** Whether the ABI jar left only a stub of the method's body, as it does unless it is inlined. */
    static boolean isStub(MethodNode m) {
      List<Integer> opcodes = new ArrayList<>();
      for (AbstractInsnNode insn : m.instructions) {
        if (insn.getOpcode() >= 0) {
          opcodes.add(insn.getOpcode());
        }
      }
      return opcodes.isEmpty() || opcodes.equals(List.of(Opcodes.ACONST_NULL, Opcodes.ATHROW));
    }

    boolean keepsMethod(String name, String desc) {
      for (MethodNode m : node.methods) {
        if (m.name.equals(name) && m.desc.equals(desc)) {
          return keepMethod(m);
        }
      }
      return true;
    }

    /** The classes the kept methods' bytecode creates or refers to by type. */
    Set<String> referencedClasses() {
      Set<String> classes = new HashSet<>();
      for (MethodNode m : node.methods) {
        if (!keepMethod(m) || m.instructions == null) {
          continue;
        }
        for (AbstractInsnNode insn : m.instructions) {
          if (insn instanceof TypeInsnNode ti) {
            classes.add(ti.desc);
          } else if (insn instanceof MethodInsnNode mi) {
            classes.add(mi.owner);
          } else if (insn instanceof FieldInsnNode fi) {
            classes.add(fi.owner);
          }
        }
      }
      return classes;
    }

    /** The owner and name of every method and field the kept methods' bytecode refers to. */
    List<String[]> references() {
      List<String[]> refs = new ArrayList<>();
      for (MethodNode m : node.methods) {
        if (!keepMethod(m) || m.instructions == null) {
          continue;
        }
        for (AbstractInsnNode insn : m.instructions) {
          if (insn instanceof MethodInsnNode mi) {
            refs.add(new String[] {mi.owner, mi.name});
          } else if (insn instanceof FieldInsnNode fi) {
            refs.add(new String[] {fi.owner, fi.name});
          }
        }
      }
      return refs;
    }

    private static List<String> jvmNames(KmProperty p) {
      List<String> names = new ArrayList<>();
      for (JvmMethodSignature s : new JvmMethodSignature[] {
            JvmExtensionsKt.getGetterSignature(p),
            JvmExtensionsKt.getSetterSignature(p),
            JvmExtensionsKt.getSyntheticMethodForAnnotations(p),
            JvmExtensionsKt.getSyntheticMethodForDelegate(p)}) {
        if (s != null) {
          names.add(s.getName());
        }
      }
      JvmFieldSignature field = JvmExtensionsKt.getFieldSignature(p);
      if (field != null) {
        names.add(field.getName());
      }
      return names;
    }

    /**
     * Whether a JVM method stays: it belongs to a kept declaration, or to no declaration the
     * metadata names at all.
     */
    private boolean keepMethod(MethodNode m) {
      String sig = m.name + m.desc;
      // Default arguments and inline suspend functions add methods of their own.
      String variantOf = null;
      for (String suffix : new String[] {"$default", "$$forInline"}) {
        if (m.name.endsWith(suffix)) {
          variantOf = m.name.substring(0, m.name.length() - suffix.length());
        }
      }
      boolean known = false;
      for (KmFunction f : functions) {
        JvmMethodSignature s = JvmExtensionsKt.getSignature(f);
        if (s == null) {
          continue;
        }
        if ((s.getName() + s.getDescriptor()).equals(sig) || s.getName().equals(variantOf)) {
          if (keptFunctions.contains(f)) {
            return true;
          }
          known = true;
        }
      }
      for (KmProperty p : properties) {
        for (JvmMethodSignature s : new JvmMethodSignature[] {
              JvmExtensionsKt.getGetterSignature(p),
              JvmExtensionsKt.getSetterSignature(p),
              JvmExtensionsKt.getSyntheticMethodForAnnotations(p),
              JvmExtensionsKt.getSyntheticMethodForDelegate(p)}) {
          if (s != null && (s.getName() + s.getDescriptor()).equals(sig)) {
            if (keptProperties.contains(p)) {
              return true;
            }
            known = true;
          }
        }
      }
      return !known;
    }

    private boolean keepField(FieldNode field) {
      boolean known = false;
      for (KmProperty p : properties) {
        JvmFieldSignature s = JvmExtensionsKt.getFieldSignature(p);
        if (s != null && s.getName().equals(field.name) && s.getDescriptor().equals(field.desc)) {
          if (keptProperties.contains(p)) {
            return true;
          }
          known = true;
        }
      }
      return !known;
    }

    /** The class with only what is kept, written from scratch so nothing dropped leaves a trace. */
    byte[] write() {
      KmPackage pkg = metadata.getKmPackage();
      pkg.getFunctions().clear();
      functions.stream().filter(keptFunctions::contains).forEach(pkg.getFunctions()::add);
      pkg.getProperties().clear();
      properties.stream().filter(keptProperties::contains).forEach(pkg.getProperties()::add);
      Metadata m = metadata.write();

      ClassNode out = new ClassNode();
      node.accept(out);
      out.methods.removeIf(method -> !keepMethod(method));
      out.fields.removeIf(field -> !keepField(field));
      out.innerClasses.removeIf(inner -> droppedLocalClasses.contains(inner.name));
      // The source map (it records the file's length) only matters when inlining from this class.
      if (out.methods.stream().allMatch(Facade::isStub)) {
        out.sourceDebug = null;
        if (out.invisibleAnnotations != null) {
          out.invisibleAnnotations.removeIf(an -> an.desc.equals("Lkotlin/jvm/internal/SourceDebugExtension;"));
        }
      }
      AnnotationNode a = new AnnotationNode(METADATA);
      a.visit("mv", m.mv());
      a.visit("k", m.k());
      a.visit("xi", m.xi());
      var d1 = a.visitArray("d1");
      for (String s : m.d1()) {
        d1.visit(null, s);
      }
      d1.visitEnd();
      var d2 = a.visitArray("d2");
      for (String s : m.d2()) {
        d2.visit(null, s);
      }
      d2.visitEnd();
      out.visibleAnnotations.replaceAll(existing -> existing.desc.equals(METADATA) ? a : existing);
      ClassWriter writer = new ClassWriter(0);
      out.accept(writer);
      return writer.toByteArray();
    }
  }

  private static Map<String, Object> values(AnnotationNode a) {
    Map<String, Object> values = new HashMap<>();
    if (a.values != null) {
      for (int i = 0; i + 1 < a.values.size(); i += 2) {
        values.put((String) a.values.get(i), a.values.get(i + 1));
      }
    }
    return values;
  }

  private static int[] ints(Object v) {
    if (v instanceof int[] a) {
      return a;
    }
    @SuppressWarnings("unchecked")
    List<Integer> l = (List<Integer>) v;
    int[] a = new int[l.size()];
    for (int i = 0; i < a.length; i++) {
      a[i] = l.get(i);
    }
    return a;
  }

  private static String[] strings(Object v) {
    @SuppressWarnings("unchecked")
    List<String> l = (List<String>) v;
    return l == null ? new String[0] : l.toArray(new String[0]);
  }
}
