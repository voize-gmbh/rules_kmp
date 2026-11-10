"""The Kotlin toolchain: compilers, builder and implicit standard libraries."""

load("@rules_java//java/common:java_info.bzl", "JavaInfo")
load("//kotlin:providers.bzl", "KlibInfo")
load("//maven:compile_versions.bzl", "maven_runtime_jars_aspect", "runtime_jars")

KotlinToolchainInfo = provider(
    doc = "Everything the Kotlin rules need to run a compilation.",
    fields = {
        "builder": "FilesToRunProvider of the compiler worker.",
        "classpath_filter": "FilesToRunProvider or None: reduces JVM compiles' dependency ABI jars to what their sources name.",
        "jvm_compiler_classpath": "list[File]: kotlinc jars.",
        "jvm_abi_gen": "File: jvm-abi-gen compiler plugin.",
        "jvm_stdlib": "JavaInfo: kotlin-stdlib, an implicit dependency of every JVM compilation.",
        "android_stdlib": "JavaInfo: kotlin-stdlib as resolved for Android.",
        "jvm_stdlib_runtime_jars": "list[depset]: the compile_version jars jvm_stdlib brings (see maven/compile_versions.bzl).",
        "android_stdlib_runtime_jars": "list[depset]: the same for android_stdlib.",
        "jvm_target": "str: -jvm-target.",
        "ksp": "JavaInfo or None: KSP2 and its runtime classpath, for kmp_ksp.",
        "native_compiler_jar": "File: kotlin-native-compiler-embeddable.jar.",
        "native_compiler_classpath": "list[File]: the Kotlin/Native compiler's classpath, patches first.",
        "konan_home": "str: exec-root relative path of the Kotlin/Native distribution.",
        "konan_data": "str: exec-root relative path of the Kotlin/Native dependency dir.",
        "native_target_files": "dict[str, depset[File]]: distribution files per Kotlin/Native target.",
        "native_platform_defs": "dict[str, depset[File]]: platform .def files per target, for cinterop.",
        "native_deps_files": "depset[File]: LLVM and libffi, needed when linking or running cinterop.",
        "native_system_caches": "dict[str, struct(dir, files)]: the distribution's stdlib and platform library caches per target.",
        "native_xcode": "bool: whether Apple targets are compiled with Xcode (macOS hosts) or with apple_toolchain.",
        "native_apple_toolchain": "depset[File]: the Apple toolchain and SDK used instead of Xcode, if any.",
        "native_apple_args": "list[str]: compiler arguments that select apple_toolchain.",
        "web_stdlibs": "dict[str, KlibInfo]: stdlib klibs for js and wasm_js.",
        "web_test_libs": "dict[str, KlibInfo]: kotlin-test klibs for js and wasm_js.",
        "compiler_version": "str",
    },
)

_NATIVE_TARGETS = ["ios_arm64", "ios_simulator_arm64", "ios_x64", "macos_arm64", "macos_x64"]

def _kotlin_toolchain_impl(ctx):
    konan_props = ctx.file.konan_properties
    konan_home = konan_props.dirname.rsplit("/", 1)[0] if konan_props else None
    data_marker = ctx.file.konan_data_marker
    konan_data = data_marker.dirname.rsplit("/", 1)[0] if data_marker else None
    native_target_files = {}
    native_platform_defs = {}
    for target, name in ctx.attr.native_targets.items():
        native_target_files[name] = target.files
    for target, name in ctx.attr.native_platform_defs.items():
        native_platform_defs[name] = target.files
    native_system_caches = {}
    for target, name in ctx.attr.native_system_caches.items():
        native_system_caches[name] = struct(
            dir = "%s/klib/cache/%s-gSTATIC-system" % (konan_home, name),
            files = target.files,
        )
    apple_args = []
    if ctx.files.native_apple_toolchain:
        libtool = [f for f in ctx.files.native_apple_toolchain if f.path.endswith("/apple-toolchain/usr/bin/libtool")][0]
        root = libtool.path[:-len("/usr/bin/libtool")]
        sdk = root.rsplit("/", 1)[0] + "/apple-sdk"
        # Without it, a Mac host would use Xcode regardless (see the apple targets patch).
        props = ["configuredAppleToolchain=true"]
        for name in native_target_files:
            # The host's own target reads the key without the host prefix.
            key = name if name == ctx.attr.native_host else "%s-%s" % (ctx.attr.native_host, name)
            props.append("targetToolchain.%s=__EXECROOT__/%s" % (key, root))
            props.append("targetSysRoot.%s=__EXECROOT__/%s" % (name, sdk))
        apple_args = ["-Xoverride-konan-properties=" + ";".join(props)]
    web_stdlibs = {}
    for target, name in ctx.attr.web_stdlibs.items():
        web_stdlibs[name] = target[KlibInfo]
    web_test_libs = {}
    for target, name in ctx.attr.web_test_libs.items():
        web_test_libs[name] = target[KlibInfo]
    info = KotlinToolchainInfo(
        builder = ctx.attr.builder[DefaultInfo].files_to_run,
        classpath_filter = ctx.attr.classpath_filter[DefaultInfo].files_to_run if ctx.attr.classpath_filter else None,
        jvm_compiler_classpath = ctx.files.jvm_compiler_classpath,
        jvm_abi_gen = ctx.file.jvm_abi_gen,
        jvm_stdlib = ctx.attr.jvm_stdlib[JavaInfo] if ctx.attr.jvm_stdlib else None,
        android_stdlib = ctx.attr.android_stdlib[JavaInfo] if ctx.attr.android_stdlib else None,
        jvm_stdlib_runtime_jars = runtime_jars([ctx.attr.jvm_stdlib] if ctx.attr.jvm_stdlib else []),
        android_stdlib_runtime_jars = runtime_jars([ctx.attr.android_stdlib] if ctx.attr.android_stdlib else []),
        jvm_target = ctx.attr.jvm_target,
        ksp = ctx.attr.ksp[JavaInfo] if ctx.attr.ksp else None,
        native_compiler_jar = ctx.file.native_compiler_jar,
        native_compiler_classpath = ctx.files.native_compiler_patches + ([ctx.file.native_compiler_jar] if ctx.file.native_compiler_jar else []),
        konan_home = konan_home,
        konan_data = konan_data,
        native_target_files = native_target_files,
        native_platform_defs = native_platform_defs,
        native_deps_files = depset(ctx.files.native_deps),
        native_system_caches = native_system_caches,
        native_xcode = not ctx.files.native_apple_toolchain,
        native_apple_toolchain = depset(ctx.files.native_apple_toolchain),
        native_apple_args = apple_args,
        web_stdlibs = web_stdlibs,
        web_test_libs = web_test_libs,
        compiler_version = ctx.attr.compiler_version,
    )
    return [info, platform_common.ToolchainInfo(kotlin = info)]

kotlin_toolchain = rule(
    implementation = _kotlin_toolchain_impl,
    attrs = {
        "builder": attr.label(cfg = "exec", executable = True, mandatory = True),
        "classpath_filter": attr.label(cfg = "exec", executable = True),
        "jvm_compiler_classpath": attr.label_list(cfg = "exec", allow_files = True),
        "jvm_abi_gen": attr.label(cfg = "exec", allow_single_file = True),
        "jvm_stdlib": attr.label(providers = [JavaInfo], aspects = [maven_runtime_jars_aspect]),
        "android_stdlib": attr.label(providers = [JavaInfo], aspects = [maven_runtime_jars_aspect]),
        "jvm_target": attr.string(default = "21"),
        "ksp": attr.label(cfg = "exec", providers = [JavaInfo], doc = "KSP2 (symbol-processing-aa-embeddable and its runtime dependencies)."),
        "native_compiler_jar": attr.label(cfg = "exec", allow_single_file = True),
        "native_compiler_patches": attr.label_list(cfg = "exec", allow_files = [".jar"], doc = "Classes that replace the compiler's own."),
        "native_host": attr.string(doc = "Kotlin/Native name of the host the distribution runs on, e.g. linux_x64."),
        "native_apple_toolchain": attr.label(
            cfg = "exec",
            allow_files = True,
            doc = "A libtool at apple-toolchain/usr/bin and an apple-sdk directory beside it, for Apple targets without Xcode.",
        ),
        "konan_properties": attr.label(cfg = "exec", allow_single_file = True),
        "konan_data_marker": attr.label(cfg = "exec", allow_single_file = True),
        "native_targets": attr.label_keyed_string_dict(cfg = "exec", allow_files = True),
        "native_platform_defs": attr.label_keyed_string_dict(cfg = "exec", allow_files = True),
        "native_deps": attr.label_list(cfg = "exec", allow_files = True),
        "native_system_caches": attr.label_keyed_string_dict(cfg = "exec", allow_files = True),
        "web_stdlibs": attr.label_keyed_string_dict(providers = [KlibInfo]),
        "web_test_libs": attr.label_keyed_string_dict(providers = [KlibInfo]),
        "compiler_version": attr.string(mandatory = True),
    },
    provides = [KotlinToolchainInfo],
)

NATIVE_TARGETS = _NATIVE_TARGETS

JVM_TOOLCHAIN_TYPE = Label("//kotlin:jvm_toolchain_type")
WEB_TOOLCHAIN_TYPE = Label("//kotlin:web_toolchain_type")
NATIVE_TOOLCHAIN_TYPE = Label("//kotlin:native_toolchain_type")
NATIVE_KLIB_TOOLCHAIN_TYPE = Label("//kotlin:native_klib_toolchain_type")
NATIVE_CACHE_TOOLCHAIN_TYPE = Label("//kotlin:native_cache_toolchain_type")

def kotlin_toolchain_info(ctx, toolchain_type):
    """The KotlinToolchainInfo resolved for `toolchain_type`, one of the types above."""
    return ctx.toolchains[toolchain_type].kotlin
