"""Kotlin compilation rules: JVM/Android jars and Native/JS/Wasm klibs."""

load("@bazel_skylib//rules:common_settings.bzl", "BuildSettingInfo")
load("@rules_java//java/common:java_common.bzl", "java_common")
load("@rules_java//java/common:java_info.bzl", "JavaInfo")
load("//kotlin:providers.bzl", "ComposeResourcesInfo", "KlibInfo", "KtCompilationInfo", "KtCompilerPluginInfo", "NativeLinkInfo")
load("//maven:compile_versions.bzl", "VERSION_CHECK_ATTRS", "check_versions", "maven_runtime_jars_aspect", "runtime_jars", "with_runtime_versions")
load("//maven:platform.bzl", "MAVEN_PLATFORM_ATTRS", "maven_platform_transition")
load(":toolchain.bzl", "JVM_TOOLCHAIN_TYPE", "NATIVE_KLIB_TOOLCHAIN_TYPE", "WEB_TOOLCHAIN_TYPE", "kotlin_toolchain_info")


_COMMON_ATTRS = {
    "srcs": attr.label_keyed_string_dict(
        allow_files = [".kt"],
        doc = "Source file -> name of the multiplatform fragment (source set) it belongs to.",
    ),
    "srcjars": attr.label_keyed_string_dict(
        allow_files = [".srcjar", ".jar"],
        doc = "Generated sources archive -> fragment name.",
    ),
    "fragments": attr.string_list(doc = "Fragments in dependency order, e.g. [commonMain, jvmMain]."),
    "refines": attr.string_list(doc = "Fragment edges as 'child:parent'."),
    "plugins": attr.label_list(providers = [KtCompilerPluginInfo]),
    "kotlinc_opts": attr.string_list(),
    "module_name": attr.string(mandatory = True),
    "maven_artifact": attr.string(doc = "group:artifact the module is published as, when that is not module_name (see maven_pom)."),
    "maven_platform_artifact": attr.string(doc = "group:artifact of this platform's Maven module, when the module is published per platform (see kmp_publication)."),
}

def _fragment_args(ctx, args):
    for f in ctx.attr.fragments:
        args.add("--fragment", f)
    for r in ctx.attr.refines:
        args.add("--refines", r)
    srcs = []
    for target, fragment in ctx.attr.srcs.items():
        for f in target.files.to_list():
            if f.extension == "java":
                args.add("--java_src", f.path)
            else:
                args.add("--src", "%s=%s" % (fragment, f.path))
            srcs.append(f)
    srcjars = []
    for target, fragment in ctx.attr.srcjars.items():
        for f in target.files.to_list():
            args.add("--srcjar", "%s=%s" % (fragment, f.path))
            srcjars.append(f)
    return srcs, srcjars

def _plugin_args(args, plugins, native):
    files = []
    for p in plugins:
        jars = p.native_jars if native else p.jvm_jars
        for j in jars:
            args.add("-Xplugin=" + j.path)
            files.append(j)
        for o in p.options:
            args.add("-P")
            args.add("plugin:%s:%s" % (p.id, o))
    return files

def _worker_requirements(mnemonic):
    return {
        "supports-workers": "1",
        "worker-key-mnemonic": mnemonic,
    }

# ---------------------------------------------------------------------------------------------
# JVM
# ---------------------------------------------------------------------------------------------

def _kmp_jvm_library_impl(ctx):
    tc = kotlin_toolchain_info(ctx, JVM_TOOLCHAIN_TYPE)
    deps = [d[JavaInfo] for d in ctx.attr.deps] + [tc.android_stdlib if ctx.file.android_jar else tc.jvm_stdlib]
    exports = [d[JavaInfo] for d in ctx.attr.exports]
    runtime_deps = [d[JavaInfo] for d in ctx.attr.runtime_deps]
    compile_only = [d[JavaInfo] for d in ctx.attr.compile_only_deps]
    friends = [d[JavaInfo] for d in ctx.attr.friends]
    plugins = [p[KtCompilerPluginInfo] for p in ctx.attr.plugins]

    jar = ctx.actions.declare_file(ctx.label.name + ".jar")
    abi_jar = ctx.actions.declare_file(ctx.label.name + "-abi.jar")
    src_jar = ctx.actions.declare_file(ctx.label.name + "-sources.jar")
    res_jar = None
    if ctx.attr.resources or ctx.files.resource_jars:
        res_jar = ctx.actions.declare_file(ctx.label.name + "-resources.jar")

    # Friends (the main module of a test) are compiled against with their full class jars: inlining
    # their internal inline functions needs synthetic classes the ABI jars leave out.
    friend_class_jars = [o.class_jar for f in friends for o in f.java_outputs if not o.class_jar.basename.endswith("-resources.jar")]
    first = friend_class_jars + [j for d in ctx.attr.classpath_first for j in d[JavaInfo].compile_jars.to_list()]

    # Like Gradle's compile classpath: direct dependencies and what they export (Gradle's api), so
    # code can't use a library it doesn't declare, and a change behind an implementation dependency
    # doesn't recompile this target. Tests see their main module's whole classpath, as in Gradle.
    classpath = depset(first, transitive = [
        d.compile_jars
        for d in deps + exports + compile_only
    ] + [f.transitive_compile_time_jars for f in friends] + ([depset([ctx.file.android_jar])] if ctx.file.android_jar else []), order = "preorder")
    if not ctx.attr.maven_compile_versions:
        classpath = with_runtime_versions(classpath, runtime_jars(
            ctx.attr.deps + ctx.attr.exports + ctx.attr.compile_only_deps + ctx.attr.friends + ctx.attr.classpath_first,
        ) + (tc.android_stdlib_runtime_jars if ctx.file.android_jar else tc.jvm_stdlib_runtime_jars))

    resource_files = [f for t in ctx.attr.resources for f in t.files.to_list()]
    outputs = struct(jar = jar, abi_jar = abi_jar, src_jar = src_jar, res_jar = res_jar)
    mode = ctx.attr._classpath_filter[BuildSettingInfo].value if tc.classpath_filter else "off"
    validations = []
    filtered_dirs = []
    if mode == "off":
        _jvm_compile(ctx, tc, "KotlinCompile", classpath, [classpath], friend_class_jars, plugins, resource_files, outputs)
    else:
        filtered, filtered_inputs, filtered_dir = _filter_classpath(ctx, tc, classpath)
        filtered_dirs.append(filtered_dir)
        _jvm_compile(ctx, tc, "KotlinCompile", filtered, filtered_inputs, friend_class_jars, plugins, resource_files, outputs)
        if mode == "verify":
            validations.append(_verify_filtered_compile(ctx, tc, classpath, friend_class_jars, plugins, resource_files, outputs))

    # Resources travel in their own jar so a module's tests can see them as directories instead,
    # like Gradle (see kmp_jvm_test.resource_dirs).
    java_info = JavaInfo(
        output_jar = jar,
        compile_jar = abi_jar,
        source_jar = src_jar,
        deps = deps,
        runtime_deps = runtime_deps,
        exports = exports,
        neverlink = ctx.attr.neverlink,
    )
    if res_jar:
        # Merged as an output of this target (not a dependency) so aspects such as Android's dexer
        # that walk targets see it.
        java_info = java_common.merge([java_info, JavaInfo(output_jar = res_jar, compile_jar = res_jar, neverlink = ctx.attr.neverlink)])
    if not ctx.attr.maven_compile_versions:
        validations.append(check_versions(ctx, classpath, java_info.transitive_runtime_jars))
    output_groups = dict(
        sources = depset([src_jar]),
        abi = depset([abi_jar]),
        resources_jar = depset([res_jar] if res_jar else []),
        kotlin_classpath = depset(filtered_dirs),
    )
    if validations:
        output_groups["_validation"] = depset(validations)
    providers = [
        DefaultInfo(
            files = depset([jar]),
            runfiles = ctx.runfiles(files = [jar]).merge_all(
                [d[DefaultInfo].default_runfiles for d in ctx.attr.data if d[DefaultInfo].default_runfiles] +
                [ctx.runfiles(files = ctx.files.data)],
            ),
        ),
        java_info,
        OutputGroupInfo(**output_groups),
        KtCompilationInfo(classpath = classpath, class_jar = jar, friend_jars = friend_class_jars, jvm_target = tc.jvm_target),
    ]
    compose = _merge_compose(ctx)
    if compose:
        providers.append(compose)
    return providers

def _jvm_compile(ctx, tc, mnemonic, classpath, classpath_inputs, friend_class_jars, plugins, resource_files, outputs):
    """Compiles the target's sources against `classpath` (Files or exec paths) into `outputs`."""
    args = ctx.actions.args()
    args.set_param_file_format("multiline")
    args.use_param_file("@%s", use_always = True)
    args.add("--mode", "jvm")
    args.add("--compiler_main", "org.jetbrains.kotlin.cli.jvm.K2JVMCompiler")
    for f in tc.jvm_compiler_classpath:
        args.add("--compiler_classpath", f.path)
    args.add("--output", outputs.jar)
    args.add("--abi_output", outputs.abi_jar)
    args.add("--abi_plugin", tc.jvm_abi_gen)
    args.add("--source_jar_output", outputs.src_jar)
    if outputs.res_jar:
        args.add("--resources_output", outputs.res_jar)
    args.add("--tmp_dir", outputs.jar.path + ".tmp")
    srcs, srcjars = _fragment_args(ctx, args)
    for target, strip in ctx.attr.resources.items():
        for f in target.files.to_list():
            path = f.short_path
            if strip and path.startswith(strip):
                path = path[len(strip):].lstrip("/")
            args.add("--resource", "%s=%s" % (f.path, path))
    for f in ctx.files.resource_jars:
        args.add("--resource_jar", f)
    args.add("--javac_arg", "--release=" + tc.jvm_target.removeprefix("1."))
    args.add("--")
    args.add("-no-stdlib")
    args.add("-no-reflect")
    args.add("-module-name", ctx.attr.module_name)
    args.add("-jvm-target", tc.jvm_target)
    args.add("-Xexpect-actual-classes")
    args.add_joined("-classpath", classpath, join_with = ":", omit_if_empty = False)
    if friend_class_jars:
        args.add_joined(friend_class_jars, join_with = ",", format_joined = "-Xfriend-paths=%s")
    plugin_files = _plugin_args(args, plugins, native = False)
    args.add_all(ctx.attr.kotlinc_opts)

    ctx.actions.run(
        mnemonic = mnemonic,
        progress_message = "Compiling Kotlin %{label}",
        executable = tc.builder,
        arguments = [args],
        inputs = depset(
            srcs + srcjars + resource_files + ctx.files.resource_jars + plugin_files,
            transitive = classpath_inputs,
        ),
        tools = tc.jvm_compiler_classpath + [tc.jvm_abi_gen],
        outputs = [outputs.jar, outputs.abi_jar, outputs.src_jar] + ([outputs.res_jar] if outputs.res_jar else []),
        execution_requirements = _worker_requirements(mnemonic),
    )

def _filterable(jar):
    # The ABI jars of Kotlin libraries built here; other jars change too rarely to be worth it.
    return not jar.is_source and jar.basename.endswith("-abi.jar")

def _filter_classpath(ctx, tc, classpath):
    """The classpath with dependency ABI jars reduced to what the sources can refer to.

    Adding a top-level declaration the sources don't name to a dependency then leaves the compile's
    inputs, and so its outputs, as they were (see ClasspathFilter.java).

    Returns:
      (classpath entries as exec paths, depsets of the files they are in, the filtered jars' directory)
    """
    entries = classpath.to_list()
    out_dir = ctx.actions.declare_directory(ctx.label.name + "_classpath")
    args = ctx.actions.args()
    args.set_param_file_format("multiline")
    args.use_param_file("@%s", use_always = True)
    srcs = [f for t in ctx.attr.srcs for f in t.files.to_list()]
    srcjars = [f for t in ctx.attr.srcjars for f in t.files.to_list()]
    args.add_all(srcs, before_each = "--src")
    args.add_all(srcjars, before_each = "--srcjar")
    paths = []
    unfiltered = []
    filtered = []
    for i, jar in enumerate(entries):
        if _filterable(jar):
            path = "%s/%d.jar" % (out_dir.path, i)
            args.add("--jar", "%s=%s" % (jar.path, path))
            filtered.append(jar)
            paths.append(path)
        else:
            unfiltered.append(jar)
            paths.append(jar.path)
    ctx.actions.run(
        mnemonic = "KotlinClasspathFilter",
        progress_message = "Filtering the classpath of %{label}",
        executable = tc.classpath_filter,
        arguments = [args],
        inputs = srcs + srcjars + filtered,
        outputs = [out_dir],
        execution_requirements = _worker_requirements("KotlinClasspathFilter"),
    )
    return paths, [depset(unfiltered + [out_dir])], out_dir

def _verify_filtered_compile(ctx, tc, classpath, friend_class_jars, plugins, resource_files, outputs):
    """Compiles again against the whole classpath; the returned check fails unless the jars match."""
    name = ctx.label.name + "_unfiltered/" + ctx.label.name
    reference = struct(
        jar = ctx.actions.declare_file(name + ".jar"),
        abi_jar = ctx.actions.declare_file(name + "-abi.jar"),
        src_jar = ctx.actions.declare_file(name + "-sources.jar"),
        res_jar = ctx.actions.declare_file(name + "-resources.jar") if outputs.res_jar else None,
    )
    _jvm_compile(ctx, tc, "KotlinCompileUnfiltered", classpath, [classpath], friend_class_jars, plugins, resource_files, reference)
    check = ctx.actions.declare_file(ctx.label.name + "_unfiltered/match")
    ctx.actions.run_shell(
        mnemonic = "KotlinClasspathFilterCheck",
        progress_message = "Checking %{label} compiles the same against its filtered classpath",
        inputs = [outputs.jar, outputs.abi_jar, reference.jar, reference.abi_jar],
        outputs = [check],
        command = "for p in \"$1 $2\" \"$3 $4\"; do cmp $p || { echo \"%s: compiling against the filtered classpath gave a different jar\" >&2; exit 1; }; done; touch \"$5\"" % ctx.label,
        arguments = [outputs.jar.path, reference.jar.path, outputs.abi_jar.path, reference.abi_jar.path, check.path],
    )
    return check

def _merge_compose(ctx):
    transitive = [
        d[ComposeResourcesInfo].transitive
        for d in ctx.attr.deps + ctx.attr.exports + ctx.attr.runtime_deps
        if ComposeResourcesInfo in d
    ]
    own = ctx.attr.compose_resources[ComposeResourcesInfo] if ctx.attr.compose_resources else None
    if not own and not transitive:
        return None
    return ComposeResourcesInfo(
        package = own.package if own else None,
        files = own.files if own else [],
        root = own.root if own else None,
        transitive = depset(
            [struct(package = own.package, files = own.files, root = own.root)] if own else [],
            transitive = transitive,
        ),
    )

kmp_jvm_library = rule(
    implementation = _kmp_jvm_library_impl,
    cfg = maven_platform_transition,
    attrs = dict(_COMMON_ATTRS, **(VERSION_CHECK_ATTRS | MAVEN_PLATFORM_ATTRS | {
        "srcs": attr.label_keyed_string_dict(
            allow_files = [".kt", ".java"],
            doc = "Source file -> name of the multiplatform fragment (source set) it belongs to; Java files are compiled with javac after the Kotlin sources, which see them.",
        ),
        "deps": attr.label_list(providers = [JavaInfo], aspects = [maven_runtime_jars_aspect]),
        "exports": attr.label_list(providers = [JavaInfo], aspects = [maven_runtime_jars_aspect]),
        "runtime_deps": attr.label_list(providers = [JavaInfo]),
        "compile_only_deps": attr.label_list(providers = [JavaInfo], aspects = [maven_runtime_jars_aspect]),
        "friends": attr.label_list(providers = [JavaInfo], aspects = [maven_runtime_jars_aspect]),
        "classpath_first": attr.label_list(
            providers = [JavaInfo],
            aspects = [maven_runtime_jars_aspect],
            doc = """Jars put first on the compile classpath, shadowing other versions of the same
classes: for libraries Gradle compiled this module against at a different version than the repo-wide
compile version (see maven_compile_versions).""",
        ),
        "maven_compile_versions": attr.bool(
            doc = """Compile against the lower versions of maven.compile_version, as a Gradle build
of the same module does, instead of the versions the platform runs with. Without it, a validation
action fails the build if a Maven module on the compile classpath is at another version than on the
runtime classpath.""",
        ),
        "resources": attr.label_keyed_string_dict(
            allow_files = True,
            doc = "Resource files -> path prefix stripped to get the path inside the jar.",
        ),
        "resource_jars": attr.label_list(allow_files = [".jar", ".zip"]),
        "compose_resources": attr.label(providers = [ComposeResourcesInfo]),
        "android_jar": attr.label(allow_single_file = True, doc = "Compile against this android.jar."),
        "data": attr.label_list(allow_files = True),
        "neverlink": attr.bool(),
        "_classpath_filter": attr.label(default = "//config:kotlin_classpath_filter", providers = [BuildSettingInfo]),
    })),
    provides = [JavaInfo],
    toolchains = [JVM_TOOLCHAIN_TYPE],
)

# ---------------------------------------------------------------------------------------------
# klib (Native, JS, Wasm)
# ---------------------------------------------------------------------------------------------

def _is_native(target):
    return target not in ("js", "wasm_js")

_APPLE_PLATFORMS = {
    "ios_arm64": apple_common.platform.ios_device,
    "ios_simulator_arm64": apple_common.platform.ios_simulator,
    "ios_x64": apple_common.platform.ios_simulator,
    "macos_arm64": apple_common.platform.macos,
    "macos_x64": apple_common.platform.macos,
}

def native_env(ctx, target):
    """Environment for actions that need the Xcode toolchain (cinterop, linking).

    Bazel fills in DEVELOPER_DIR and SDKROOT (of the target's SDK) from these variables.
    """
    xcode = ctx.attr._xcode_config[apple_common.XcodeVersionConfig]
    env = {"LIBCLANG_DISABLE_CRASH_RECOVERY": "1"}
    env.update(apple_common.apple_host_system_env(xcode))
    env.update(apple_common.target_apple_env(xcode, _APPLE_PLATFORMS[target]))
    return env

def native_sysprops(tc):
    return [
        "konan.home=abs:" + tc.konan_home,
        "konan.data.dir=abs:" + tc.konan_data,
    ]

_LEAF_PREFIX = {
    "ios_arm64": "iosArm64",
    "ios_simulator_arm64": "iosSimulatorArm64",
    "ios_x64": "iosX64",
    "macos_arm64": "macosArm64",
    "macos_x64": "macosX64",
    "js": "js",
    "wasm_js": "wasmJs",
}

def _leaf_fragment_args(ctx, args):
    """Adds the platform's own source set as an empty leaf fragment when it has no sources.

    K2 treats only the leaf fragment as platform code; without it, commonMain would be the leaf and
    usages of optional expectations such as @JvmInline would be rejected there.
    """
    fragments = ctx.attr.fragments
    if not fragments:
        return
    suffix = "Test" if fragments[0].endswith("Test") else "Main"
    leaf = _LEAF_PREFIX[ctx.attr.target] + suffix
    if leaf in fragments:
        return
    parents = {r.split(":")[1]: True for r in ctx.attr.refines}
    args.add("--fragment", leaf)
    for f in fragments:
        if f not in parents:
            args.add("--refines", "%s:%s" % (leaf, f))

def _kmp_klib_impl(ctx):
    target = ctx.attr.target
    native = _is_native(target)
    tc = kotlin_toolchain_info(ctx, NATIVE_KLIB_TOOLCHAIN_TYPE if native else WEB_TOOLCHAIN_TYPE)
    deps = [d[KlibInfo] for d in ctx.attr.deps]
    exports = [d[KlibInfo] for d in ctx.attr.exports]
    friends = [d[KlibInfo] for d in ctx.attr.friends]
    plugins = [p[KtCompilerPluginInfo] for p in ctx.attr.plugins]
    if not native:
        deps = deps + [tc.web_stdlibs[target]]

    klib = ctx.actions.declare_file(ctx.label.name + ".klib")
    header = ctx.actions.declare_file(ctx.label.name + ".header.klib") if native else None
    libraries = depset(transitive = [d.transitive_klibs for d in deps + exports + friends], order = "postorder")

    # Compile against header klibs, so a change that keeps a dependency's ABI doesn't recompile
    # this library. Friends see internal declarations, which only their full klibs have.
    friend_klibs = [k for f in friends for k in f.klibs]
    friend_headers = {h: True for f in friends for h in f.header_klibs}
    compile_libraries = [
        l
        for l in depset(transitive = [d.compile_klibs for d in deps + exports + friends], order = "postorder").to_list()
        if l not in friend_headers
    ] + friend_klibs

    args = ctx.actions.args()
    args.set_param_file_format("multiline")
    args.use_param_file("@%s", use_always = True)
    args.add("--mode", "klib")
    args.add("--tmp_dir", klib.path + ".tmp")
    tools = []
    if native:
        args.add("--compiler_main", "org.jetbrains.kotlin.cli.bc.K2Native")
        args.add("--compiler_classpath", tc.native_compiler_jar)
        for p in native_sysprops(tc):
            args.add("--sysprop", p)
        tools.append(tc.native_compiler_jar)
    else:
        args.add("--compiler_main", "org.jetbrains.kotlin.cli.js.K2JSCompiler")
        for f in tc.jvm_compiler_classpath:
            args.add("--compiler_classpath", f.path)
        tools.extend(tc.jvm_compiler_classpath)
    srcs, srcjars = _fragment_args(ctx, args)
    _leaf_fragment_args(ctx, args)
    args.add("--")
    if native:
        args.add("-target", target)
        args.add("-produce", "library")
        args.add("-o", klib.path[:-len(".klib")])
        args.add("-module-name", ctx.attr.module_name)
        # Like Gradle (the project name): Objective-C export prefixes clashing names with it.
        args.add("-Xshort-module-name=" + (ctx.attr.short_module_name or ctx.attr.module_name.rsplit(":", 1)[-1]))
        # Like Gradle: the klib keeps the KDoc, which frameworks export into their headers.
        args.add("-Xexport-kdoc")
        args.add("-Xoverride-konan-properties=airplaneMode=true")
        args.add("-Xheader-klib-path=" + header.path)
        for l in compile_libraries:
            args.add("-library", l)
        if friend_klibs:
            args.add_joined("-friend-modules", friend_klibs, join_with = ":")
        for k in ctx.files.cinterop_klibs:
            args.add("-library", k)
    else:
        args.add("-Xir-produce-klib-file")
        args.add("-ir-output-dir", klib.dirname)
        args.add("-ir-output-name", ctx.label.name)
        args.add("-Xir-module-name=" + ctx.attr.module_name)
        if target == "wasm_js":
            args.add("-Xwasm")
            args.add("-Xwasm-target=wasm-js")
        args.add_joined("-libraries", libraries, join_with = ":")
        friend_klibs = [k for f in friends for k in f.klibs]
        if friend_klibs:
            args.add_joined(friend_klibs, join_with = ":", format_joined = "-Xfriend-modules=%s")
    args.add("-Xexpect-actual-classes")

    # Store source paths relative to the exec root so klibs are identical across machines.
    args.add("-Xklib-relative-path-base=__EXECROOT__")
    args.add("-Xklib-normalize-absolute-path")
    plugin_files = _plugin_args(args, plugins, native = native)
    args.add_all(ctx.attr.kotlinc_opts)

    if native:
        inputs = depset(srcs + srcjars + plugin_files + ctx.files.cinterop_klibs + compile_libraries, transitive = [tc.native_target_files[target]])
    else:
        inputs = depset(srcs + srcjars + plugin_files, transitive = [libraries])
    ctx.actions.run(
        mnemonic = "KotlinNativeCompile" if native else "KotlinJsCompile",
        progress_message = "Compiling Kotlin %{label} (" + target + ")",
        executable = tc.builder,
        arguments = [args],
        inputs = inputs,
        tools = tools,
        outputs = [klib] + ([header] if header else []),
        execution_requirements = _worker_requirements("KotlinNativeCompile" if native else "KotlinJsCompile"),
    )

    own_klibs = [klib] + ctx.files.cinterop_klibs
    header_klibs = ([header] if header else [klib]) + ctx.files.cinterop_klibs
    linked = deps + exports + [t[KlibInfo] for t in ctx.attr.cinterop_klibs if KlibInfo in t]
    link_infos = [t[NativeLinkInfo] for t in ctx.attr.link_inputs if NativeLinkInfo in t]
    link_files = [f for t in ctx.attr.link_inputs if NativeLinkInfo not in t for f in t.files.to_list()]
    linkopts = depset(ctx.attr.linkopts, transitive = [d.native_linkopts for d in linked] + [i.linkopts for i in link_infos])
    link_inputs = depset(link_files, transitive = [d.native_link_inputs for d in linked] + [i.inputs for i in link_infos])
    runtime_files = depset(transitive = [d.native_runtime_files for d in linked if getattr(d, "native_runtime_files", None)] + [i.runtime_files for i in link_infos])
    compose_files = []
    return [
        DefaultInfo(files = depset([klib])),
        KlibInfo(
            target = target,
            klibs = own_klibs,
            transitive_klibs = depset(own_klibs, transitive = [libraries], order = "postorder"),
            header_klibs = header_klibs,
            compile_klibs = depset(header_klibs, transitive = [d.compile_klibs for d in deps + exports + friends], order = "postorder"),
            module_name = ctx.attr.module_name,
            native_linkopts = linkopts,
            native_link_inputs = link_inputs,
            native_runtime_files = runtime_files,
            resources = depset(compose_files, transitive = [d.resources for d in deps + exports]),
        ),
    ] + ([_merge_compose(ctx)] if _merge_compose(ctx) else [])

_KLIB_ATTRS = dict(_COMMON_ATTRS, **{
    "target": attr.string(mandatory = True),
    "short_module_name": attr.string(),
    "deps": attr.label_list(providers = [KlibInfo]),
    "exports": attr.label_list(providers = [KlibInfo]),
    "runtime_deps": attr.label_list(providers = [KlibInfo]),
    "friends": attr.label_list(providers = [KlibInfo]),
    "cinterop_klibs": attr.label_list(allow_files = [".klib"]),
    "linkopts": attr.string_list(),
    "link_inputs": attr.label_list(allow_files = True),
    "compose_resources": attr.label(providers = [ComposeResourcesInfo]),
})

kmp_native_klib = rule(
    implementation = _kmp_klib_impl,
    attrs = _KLIB_ATTRS,
    provides = [KlibInfo],
    toolchains = [NATIVE_KLIB_TOOLCHAIN_TYPE],
)

kmp_web_klib = rule(
    implementation = _kmp_klib_impl,
    attrs = _KLIB_ATTRS,
    provides = [KlibInfo],
    toolchains = [WEB_TOOLCHAIN_TYPE],
)

def kmp_klib(target, **kwargs):
    """A Kotlin/Native, JS or Wasm klib for `target`."""
    if _is_native(target):
        kmp_native_klib(target = target, **kwargs)
    else:
        kmp_web_klib(target = target, **kwargs)

def _kmp_jvm_rewrap_impl(ctx):
    lib = ctx.attr.lib[JavaInfo]
    outputs = lib.java_outputs[0]
    res = ctx.attr.lib[OutputGroupInfo].resources_jar.to_list()
    outputs = [o for o in lib.java_outputs if o.class_jar not in res][0]
    info = JavaInfo(
        output_jar = outputs.class_jar,
        compile_jar = outputs.compile_jar,
        source_jar = outputs.source_jars.to_list()[0] if outputs.source_jars else None,
        deps = [d[JavaInfo] for d in ctx.attr.deps],
        runtime_deps = [d[JavaInfo] for d in ctx.attr.runtime_deps],
        exports = [d[JavaInfo] for d in ctx.attr.exports],
    )
    if res:
        info = java_common.merge([info] + [JavaInfo(output_jar = r, compile_jar = r) for r in res])
    return [DefaultInfo(files = depset([outputs.class_jar])), info, ctx.attr.lib[OutputGroupInfo]]

kmp_jvm_rewrap = rule(
    implementation = _kmp_jvm_rewrap_impl,
    doc = """The jar of a JVM library with its dependencies swapped for another platform's.

Android consumes modules that have no Android target through their JVM jar, but resolves their
third-party dependencies for Android (as Gradle does), so an app never sees two variants of one
library.""",
    attrs = {
        "lib": attr.label(providers = [JavaInfo], mandatory = True),
        "deps": attr.label_list(providers = [JavaInfo]),
        "exports": attr.label_list(providers = [JavaInfo]),
        "runtime_deps": attr.label_list(providers = [JavaInfo]),
    },
    provides = [JavaInfo],
)
