"""KSP2 (Kotlin Symbol Processing) as a source generator for the Kotlin rules."""

load("@rules_java//java/common:java_info.bzl", "JavaInfo")
load("//kotlin:providers.bzl", "KlibInfo")
load(":toolchain.bzl", "JVM_TOOLCHAIN_TYPE", "kotlin_toolchain_info")

def _kmp_ksp_impl(ctx):
    srcjar = ctx.actions.declare_file(ctx.label.name + ".srcjar")
    resjar = ctx.actions.declare_file(ctx.label.name + "-resources.jar")
    ksp = kotlin_toolchain_info(ctx, JVM_TOOLCHAIN_TYPE).ksp
    if not ksp:
        fail("kmp_ksp needs the ksp attribute of the JVM kotlin_toolchain")
    ksp_cp = ksp.transitive_runtime_jars
    processor_cp = depset(transitive = [p[JavaInfo].transitive_runtime_jars for p in ctx.attr.processors])
    native = ctx.attr.mode == "native"
    if native:
        libraries = depset(transitive = [d[KlibInfo].transitive_klibs for d in ctx.attr.deps + ctx.attr.friends])
    else:
        # The compilation's own classpath, as Gradle gives KSP (see kmp_jvm_library).
        libraries = depset(transitive = [d[JavaInfo].compile_jars for d in ctx.attr.deps] +
                                        [f[JavaInfo].transitive_compile_time_jars for f in ctx.attr.friends])

    args = ctx.actions.args()
    args.set_param_file_format("multiline")
    args.use_param_file("@%s", use_always = True)
    args.add("--main", {
        "jvm": "com.google.devtools.ksp.cmdline.KSPJvmMain",
        "native": "com.google.devtools.ksp.cmdline.KSPNativeMain",
    }[ctx.attr.mode])
    args.add("--out_srcjar", srcjar)
    args.add("--out_resjar", resjar)
    args.add("--tmp", srcjar.path + ".tmp")
    args.add_all(ksp_cp, before_each = "--ksp_cp")
    args.add_all(processor_cp, before_each = "--processor_cp")
    for f in ctx.files.srcs:
        args.add("--src", "main=" + f.path)
    for f in ctx.files.common_srcs:
        args.add("--src", "common=" + f.path)
    args.add("--arg", "-module-name=" + ctx.attr.module_name)
    args.add("--arg", "-language-version=" + ctx.attr.language_version)
    args.add("--arg", "-api-version=" + ctx.attr.language_version)
    args.add_joined("--arg", libraries, join_with = ":", format_joined = "-libraries=%s", omit_if_empty = False)
    if native:
        args.add("--arg", "-target=" + ctx.attr.target)
    else:
        args.add("--arg", "-jvm-target=21")
    if ctx.attr.options:
        args.add("--arg", "-processor-options=" + ":".join(["%s=%s" % (k, v) for k, v in sorted(ctx.attr.options.items())]))
    ctx.actions.run(
        mnemonic = "KotlinKsp",
        progress_message = "Running KSP for %{label}",
        executable = ctx.executable._runner,
        arguments = [args],
        inputs = depset(ctx.files.srcs + ctx.files.common_srcs, transitive = [ksp_cp, processor_cp, libraries]),
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
        "common_srcs": attr.label_list(allow_files = [".kt"], doc = "Sources of common (expect) source sets."),
        "deps": attr.label_list(doc = "Dependencies (JavaInfo or KlibInfo) of the compilation."),
        "friends": attr.label_list(doc = "The main module of a test compilation, whose whole classpath it sees."),
        "processors": attr.label_list(providers = [JavaInfo], cfg = "exec"),
        "options": attr.string_dict(),
        "mode": attr.string(default = "jvm", values = ["jvm", "native"]),
        "target": attr.string(doc = "Kotlin/Native target in native mode."),
        "module_name": attr.string(mandatory = True),
        "language_version": attr.string(default = "2.3"),
        "_runner": attr.label(default = "//kotlin/ksp:runner", executable = True, cfg = "exec"),
    },
    toolchains = [JVM_TOOLCHAIN_TYPE],
)
