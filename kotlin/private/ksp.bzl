"""KSP2 (Kotlin Symbol Processing) as a source generator for the Kotlin rules."""

load("@rules_java//java/common:java_info.bzl", "JavaInfo")
load("//kotlin:providers.bzl", "KlibInfo")
load("//maven:compile_versions.bzl", "maven_runtime_jars_aspect", "runtime_jars", "with_runtime_versions")
load(":toolchain.bzl", "JVM_TOOLCHAIN_TYPE", "NATIVE_KLIB_TOOLCHAIN_TYPE", "kotlin_toolchain_info")

_MAIN_CLASSES = {
    "common": "com.google.devtools.ksp.cmdline.KSPCommonMain",
    "jvm": "com.google.devtools.ksp.cmdline.KSPJvmMain",
    "native": "com.google.devtools.ksp.cmdline.KSPNativeMain",
}

def _kmp_ksp_impl(ctx):
    srcjar = ctx.actions.declare_file(ctx.label.name + ".srcjar")
    resjar = ctx.actions.declare_file(ctx.label.name + "-resources.jar")
    jvm_tc = kotlin_toolchain_info(ctx, JVM_TOOLCHAIN_TYPE)
    ksp = jvm_tc.ksp
    if not ksp:
        fail("kmp_ksp needs the ksp attribute of the JVM kotlin_toolchain")
    ksp_cp = ksp.transitive_runtime_jars
    processor_cp = depset(transitive = [p[JavaInfo].transitive_runtime_jars for p in ctx.attr.processors])
    mode = ctx.attr.mode
    dist_files = depset()
    dist_klibs = []
    if mode == "native" or (mode == "common" and ctx.attr.target):
        # The compiler adds the distribution's stdlib and platform libraries itself; KSP needs them
        # listed.
        native_tc = kotlin_toolchain_info(ctx, NATIVE_KLIB_TOOLCHAIN_TYPE)
        dist_files = native_tc.native_target_files[ctx.attr.target]
        roots = [native_tc.konan_home + "/klib/common/", "%s/klib/platform/%s/" % (native_tc.konan_home, ctx.attr.target)]
        for f in dist_files.to_list():
            for root in roots:
                if f.path.startswith(root):
                    klib = root + f.path[len(root):].split("/", 1)[0]
                    if klib not in dist_klibs:
                        dist_klibs.append(klib)
    if mode == "native":
        libraries = depset(transitive = [d[KlibInfo].transitive_klibs for d in ctx.attr.deps + ctx.attr.friends])
    else:
        # The compilation's own classpath, as Gradle gives KSP (see kmp_jvm_library). A common
        # run reads the klibs of KlibInfo dependencies and the jars of the others.
        java_deps = [d for d in ctx.attr.deps if JavaInfo in d]
        libraries = depset(transitive = [d[JavaInfo].compile_jars for d in java_deps] +
                                        [f[JavaInfo].transitive_compile_time_jars for f in ctx.attr.friends])
        if not ctx.attr.maven_compile_versions:
            libraries = with_runtime_versions(libraries, runtime_jars(java_deps + ctx.attr.friends))
        if mode == "common":
            libraries = depset(transitive = [libraries] + [d[KlibInfo].transitive_klibs for d in ctx.attr.deps if KlibInfo in d])
        if ctx.file.android_jar:
            libraries = depset([ctx.file.android_jar], transitive = [libraries], order = "preorder")

    # A common run sees all of its sources as common sources, like Gradle's metadata compilation.
    main_root = "common" if mode == "common" else "main"
    args = ctx.actions.args()
    args.set_param_file_format("multiline")
    args.use_param_file("@%s", use_always = True)
    args.add("--main", _MAIN_CLASSES[mode])
    args.add("--out_srcjar", srcjar)
    args.add("--out_resjar", resjar)
    args.add("--tmp", srcjar.path + ".tmp")
    args.add_all(ksp_cp, before_each = "--ksp_cp")
    args.add_all(processor_cp, before_each = "--processor_cp")
    for f in ctx.files.common_srcs:
        args.add("--src", "common=" + f.path)
    for f in ctx.files.srcs:
        args.add("--src", main_root + "=" + f.path)
    for f in ctx.files.srcjars:
        args.add("--srcjar", main_root + "=" + f.path)
    args.add("--arg", "-module-name=" + ctx.attr.module_name)
    args.add("--arg", "-language-version=" + ctx.attr.language_version)
    args.add("--arg", "-api-version=" + ctx.attr.language_version)
    args.add_joined("--arg", dist_klibs + [f.path for f in libraries.to_list()] if dist_klibs else libraries, join_with = ":", format_joined = "-libraries=%s", omit_if_empty = False)
    if mode == "native":
        args.add("--arg", "-target=" + ctx.attr.target)
    elif mode == "jvm":
        args.add("--arg", "-jvm-target=" + jvm_tc.jvm_target)
    else:
        # Required by the command line, but KSP2 analyses common sources for its default common
        # platform (JVM, JS and Native) whatever it says, as for Gradle's metadata compilation.
        args.add("--arg", "-targets=")
    if ctx.attr.no_sources:
        args.add("--no_sources", "true")
    if ctx.attr.options:
        args.add("--arg", "-processor-options=" + ":".join(["%s=%s" % (k, v) for k, v in sorted(ctx.attr.options.items())]))
    ctx.actions.run(
        mnemonic = "KotlinKsp",
        progress_message = "Running KSP for %{label}",
        executable = ctx.executable._runner,
        arguments = [args],
        inputs = depset(ctx.files.srcs + ctx.files.srcjars + ctx.files.common_srcs, transitive = [ksp_cp, processor_cp, libraries, dist_files]),
        outputs = [srcjar, resjar],
    )
    return [
        DefaultInfo(files = depset([srcjar])),
        OutputGroupInfo(resources = depset([resjar])),
    ]

kmp_ksp = rule(
    implementation = _kmp_ksp_impl,
    doc = "Runs KSP processors over Kotlin sources and outputs the generated sources as a srcjar.",
    attrs = {
        "srcs": attr.label_list(allow_files = [".kt", ".java"]),
        "srcjars": attr.label_list(allow_files = [".srcjar", ".jar"], doc = "Generated sources of the compilation, read like `srcs`."),
        "common_srcs": attr.label_list(allow_files = [".kt"], doc = "Sources of common (expect) source sets."),
        "deps": attr.label_list(doc = "Dependencies (JavaInfo or KlibInfo) of the compilation.", aspects = [maven_runtime_jars_aspect]),
        "friends": attr.label_list(doc = "The main module of a test compilation, whose whole classpath it sees.", aspects = [maven_runtime_jars_aspect]),
        "maven_compile_versions": attr.bool(doc = "Resolve against the versions of maven.compile_version, as the compilation does (see kmp_jvm_library)."),
        "android_jar": attr.label(allow_single_file = [".jar"], doc = "The android.jar of an Android compilation."),
        "processors": attr.label_list(providers = [JavaInfo], cfg = "exec"),
        "options": attr.string_dict(),
        "mode": attr.string(
            default = "jvm",
            values = ["jvm", "native", "common"],
            doc = "The platform KSP analyses the sources for: jvm, native (for `target`) or common, " +
                  "the metadata compilation of common sources that Gradle's kspCommonMainMetadata runs.",
        ),
        "target": attr.string(doc = "Kotlin/Native target in native mode. In common mode, the target whose distribution stdlib and platform libraries are read with klib dependencies."),
        "no_sources": attr.bool(doc = "Fail when the processors generate Kotlin or Java, for runs whose generated code nothing compiles."),
        "module_name": attr.string(mandatory = True),
        "language_version": attr.string(default = "2.3"),
        "_runner": attr.label(default = "//kotlin/ksp:runner", executable = True, cfg = "exec"),
    },
    toolchains = [JVM_TOOLCHAIN_TYPE, config_common.toolchain_type(NATIVE_KLIB_TOOLCHAIN_TYPE, mandatory = False)],
)
