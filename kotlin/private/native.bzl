"""Kotlin/Native linking (test executables, frameworks) and cinterop."""

load("@rules_java//java/common:java_common.bzl", "java_common")
load("//apple:native_deps.bzl", "SWIFT_RUNTIME_ATTR", "apple_compile_info", "apple_link_info")
load("//apple:transitions.bzl", "apple_target_transition")
load("//kotlin:providers.bzl", "ComposeResourcesInfo", "KlibInfo", "NativeCacheInfo", "NativeLinkInfo")
load(":compile.bzl", "native_env", "native_sysprops")
load(":native_cache.bzl", "DEBUG_TRANSPARENT_STEPPING_ATTR", "IOS_MINIMUM_OS_ATTR", "debug_stepping_args", "konan_properties", "link_caches", "native_cache_aspect")
load(":toolchain.bzl", "NATIVE_TOOLCHAIN_TYPE", "kotlin_toolchain_info")

_XCODE_CONFIG = "@apple_support//xcode:version_config"

# Kotlin/Native's Apple targets build in a Mac's host configuration: builds for other platforms
# skip them, instead of failing to find Xcode's toolchains.
MACOS_ONLY = [Label("@platforms//os:macos")]

_PATH_FLAGS = ["-I", "-iquote", "-isystem", "-F", "-fmodule-map-file="]

def _absolute(opt):
    for f in _PATH_FLAGS:
        if opt.startswith(f) and not opt[len(f):].startswith("/"):
            return f + "__EXECROOT__/" + opt[len(f):]
    return opt

def _kmp_cinterop_impl(ctx):
    tc = kotlin_toolchain_info(ctx, NATIVE_TOOLCHAIN_TYPE)
    target = ctx.attr.target
    compile = apple_compile_info(ctx.attr.deps)
    link = apple_link_info(ctx.attr.deps, ctx.attr._swift_runtime, ctx.attr.linkopts)
    lib_infos = [d[KlibInfo] for d in ctx.attr.libraries]

    def_file = ctx.file.def_file
    if not def_file:
        def_file = ctx.actions.declare_file(ctx.label.name + ".def")
        lines = ["language = Objective-C"]
        if ctx.attr.headers:
            lines.append("headers = " + " ".join(ctx.attr.headers))
        if ctx.attr.modules:
            lines.append("modules = " + " ".join(ctx.attr.modules))
        ctx.actions.write(def_file, "\n".join(lines) + "\n")

    klib = ctx.actions.declare_file(ctx.label.name + ".klib")
    tmp = klib.path + ".tmp"
    args = ctx.actions.args()
    args.add("-target", target)
    args.add("-def", def_file)
    args.add("-pkg", ctx.attr.package)
    args.add("-o", klib.path[:-len(".klib")])
    args.add("-Xmodule-name", ctx.attr.module_name or ctx.label.name)
    args.add("-Xtemporary-files-dir", tmp)
    args.add("-Xoverride-konan-properties", "airplaneMode=true")
    framework_dirs = []
    for f in ctx.files.frameworks:
        d = f.path.split(".framework/", 1)[0].rsplit("/", 1)[0]
        if d not in framework_dirs:
            framework_dirs.append(d)
            args.add("-compiler-option", "-F__EXECROOT__/" + d)
    for o in compile.opts:
        args.add("-compiler-option", _absolute(o))
    for d in ctx.files.include_dirs:
        args.add("-compiler-option", "-I__EXECROOT__/" + d.path)
    args.add_all(ctx.attr.compiler_opts, before_each = "-compiler-option")
    args.add("-compiler-option", "-fmodules-cache-path=__EXECROOT__/" + tmp + "/modules")
    libraries = depset(transitive = [i.transitive_klibs for i in lib_infos])
    args.add_all(libraries, before_each = "-library")

    java = ctx.attr._java_runtime[java_common.JavaRuntimeInfo]
    ctx.actions.run_shell(
        mnemonic = "KotlinCInterop",
        progress_message = "Generating Kotlin/Native bindings %{label} (" + target + ")",
        command = """set -e
mkdir -p "$5"
java="$1"; home="$PWD/$2"; data="$PWD/$3"; jar="$4"; shift 5
# cinterop parses headers from a temporary file outside the execroot.
set -- "${@//__EXECROOT__/$PWD}"
exec "$java" -Xmx2g -XX:TieredStopAtLevel=1 -Dfile.encoding=UTF-8 \
  -Dkonan.home="$home" -Dkonan.data.dir="$data" \
  -cp "$jar" org.jetbrains.kotlin.cli.utilities.MainKt cinterop -Xkonan-data-dir "$data" "$@"
""",
        arguments = [java.java_executable_exec_path, tc.konan_home, tc.konan_data, tc.native_compiler_jar.path, tmp, args],
        inputs = depset(
            [def_file] + ctx.files.include_dirs + ctx.files.srcs + ctx.files.frameworks,
            transitive = [compile.inputs, libraries, tc.native_target_files[target], tc.native_deps_files],
        ),
        tools = depset([tc.native_compiler_jar], transitive = [java.files]),
        outputs = [klib],
        env = native_env(ctx, target),
        execution_requirements = {"requires-darwin": "1"},
    )

    linkopts = depset(transitive = [link.linkopts] + [i.native_linkopts for i in lib_infos])
    link_inputs = depset(transitive = [link.inputs] + [i.native_link_inputs for i in lib_infos])
    runtime = depset(transitive = [link.runtime_files] + [getattr(i, "native_runtime_files", depset()) for i in lib_infos])
    return [
        DefaultInfo(files = depset([klib])),
        KlibInfo(
            target = target,
            klibs = [klib],
            transitive_klibs = depset([klib], transitive = [libraries], order = "postorder"),
            header_klibs = [klib],
            compile_klibs = depset([klib], transitive = [i.compile_klibs for i in lib_infos], order = "postorder"),
            module_name = ctx.attr.module_name or ctx.label.name,
            native_linkopts = linkopts,
            native_link_inputs = link_inputs,
            native_runtime_files = runtime,
            resources = depset(),
        ),
        NativeLinkInfo(linkopts = linkopts, inputs = link_inputs, runtime_files = runtime),
    ]

kmp_cinterop = rule(
    implementation = _kmp_cinterop_impl,
    doc = """Kotlin/Native bindings for Objective-C/C headers (the cinterop tool), as a klib.

The headers come from a .def file or from `headers`/`modules` (like the CocoaPods Gradle plugin's
generated .def). `deps` are Objective-C/Swift targets (CocoaPods) built for `target`: their headers,
module maps and framework search paths are passed to clang, and their libraries are linked into
every executable that includes these bindings.""",
    attrs = {
        "target": attr.string(mandatory = True, doc = "Kotlin/Native target, e.g. ios_arm64."),
        "package": attr.string(mandatory = True, doc = "Kotlin package of the bindings."),
        "module_name": attr.string(doc = "Unique name of the klib; defaults to the target name."),
        "def_file": attr.label(allow_single_file = [".def"]),
        "headers": attr.string_list(doc = "Headers to generate bindings for (.def `headers`)."),
        "modules": attr.string_list(doc = "Clang modules to generate bindings for (.def `modules`)."),
        "compiler_opts": attr.string_list(doc = "Extra clang flags, e.g. -fmodules."),
        "include_dirs": attr.label_list(allow_files = True, doc = "Directories added with -I."),
        "srcs": attr.label_list(allow_files = True, doc = "Headers the .def file includes."),
        "frameworks": attr.label_list(
            allow_files = True,
            doc = "Files of frameworks searched before those of `deps` (-F).",
        ),
        "deps": attr.label_list(cfg = apple_target_transition, doc = "Objective-C/Swift libraries (CcInfo/SwiftInfo)."),
        "libraries": attr.label_list(providers = [KlibInfo], doc = "cinterop klibs these bindings depend on."),
        "linkopts": attr.string_list(doc = "Linker flags for executables using these bindings."),
        "cacheable": attr.bool(default = True, doc = "Whether debug binaries may use a static cache of these bindings (see native_cache.bzl)."),
        "_java_runtime": attr.label(default = "@bazel_tools//tools/jdk:current_java_runtime", cfg = "exec", providers = [java_common.JavaRuntimeInfo]),
        "_swift_runtime": SWIFT_RUNTIME_ATTR,
        "_xcode_config": attr.label(default = _XCODE_CONFIG),
    },
    provides = [KlibInfo],
    toolchains = [NATIVE_TOOLCHAIN_TYPE],
)

def _link_args(ctx, tc, target, produce, out_path, include, libraries, linkopts, extra = []):
    args = ctx.actions.args()
    args.set_param_file_format("multiline")
    args.use_param_file("@%s", use_always = True)
    args.add("--mode", "raw")
    args.add("--tmp_dir", out_path + ".tmp")
    args.add("--compiler_main", "org.jetbrains.kotlin.cli.bc.K2Native")
    args.add("--compiler_classpath", tc.native_compiler_jar)
    for p in native_sysprops(tc):
        args.add("--sysprop", p)
    args.add("--")
    args.add("-target", target)
    args.add("-produce", produce)
    args.add("-o", out_path)
    args.add(konan_properties(target, ctx.attr._ios_minimum_os))
    args.add_all(debug_stepping_args(tc, ctx.attr._debug_transparent_stepping))
    # Some backend lowerings resolve the dependency directory from this flag only.
    args.add("-Xkonan-data-dir=" + tc.konan_data)
    # The builder replaces the token with the exec root, which differs per sandbox.
    args.add("-Xdebug-prefix-map=__EXECROOT__=.")
    for k in include:
        args.add("-Xinclude=" + k.path)
    for l in libraries:
        args.add("-library", l)
    for o in linkopts:
        # NativeLinkInfo keeps a flag and its value (e.g. "-framework UIKit") in one entry.
        args.add_all(o.split(" "), before_each = "-linker-option")
    # ld's debug map names the archives it linked; pods' come by absolute path, which includes the
    # sandbox, so every link would differ.
    args.add_all(["-oso_prefix", "."], before_each = "-linker-option")
    args.add_all(extra)
    return args

def _native_link(ctx, infos):
    """Linker flags, inputs and runtime frameworks of `infos` (KlibInfo) and the link_inputs attr."""
    link_infos = [t[NativeLinkInfo] for t in ctx.attr.link_inputs if NativeLinkInfo in t]
    files = [f for t in ctx.attr.link_inputs if NativeLinkInfo not in t for f in t.files.to_list()]
    linkopts = depset(
        ctx.attr.linkopts,
        transitive = [i.native_linkopts for i in infos] + [i.linkopts for i in link_infos],
    )
    inputs = depset(files, transitive = [i.native_link_inputs for i in infos] + [i.inputs for i in link_infos])
    runtime = depset(transitive = [
        i.native_runtime_files
        for i in infos
        if getattr(i, "native_runtime_files", None)
    ] + [i.runtime_files for i in link_infos])
    return struct(linkopts = linkopts.to_list(), inputs = inputs.to_list(), runtime = runtime.to_list())

# Linking a large app framework needs more heap than the compile workers have. Each link runs in
# its own JVM, which also returns the memory when done.
_LINK_HEAP = "10g"

def _link_resources(_os, _inputs_size):
    # Above half of Bazel's default memory budget on 32 GB machines: one link at a time.
    return {"cpu": 2, "memory": 12288}

def _run_link(ctx, tc, target, args, inputs, outputs, mnemonic, message, caches):
    jvm = ctx.actions.args()
    jvm.add("--jvm_flag=-Xmx" + _LINK_HEAP)
    ctx.actions.run(
        mnemonic = mnemonic,
        progress_message = message,
        executable = tc.builder,
        arguments = [jvm] + caches.builder_args + [args],
        inputs = depset(inputs, transitive = [tc.native_target_files[target], tc.native_deps_files, caches.inputs]),
        tools = [tc.native_compiler_jar],
        outputs = outputs,
        # Apple's libtool and ld store timestamps in archives and debug maps otherwise.
        env = native_env(ctx, target) | {"ZERO_AR_DATE": "1"},
        execution_requirements = {"requires-darwin": "1"},
        resource_set = _link_resources,
    )

def _framework_dirs(runtime):
    """Directories holding the dynamic frameworks, as runfiles paths for DYLD_FRAMEWORK_PATH."""
    dirs = []
    for f in runtime:
        parent = f.dirname
        if parent.endswith(".framework"):
            d = f.short_path.rsplit("/", 2)[0]
            if d not in dirs:
                dirs.append(d)
    return dirs

_SIM_RUNNER = """#!/usr/bin/env bash
# Runs a Kotlin/Native test binary on an iOS simulator, like the ios-simulator-tests Gradle plugin:
# the "{device}" device of the newest installed iOS runtime, booted if necessary.
set -euo pipefail
{setup}
runtime=$(xcrun simctl list --json runtimes iOS | /usr/bin/python3 -c 'import json,sys; rs=[r["identifier"] for r in json.load(sys.stdin)["runtimes"] if r.get("isAvailable")]; print(sorted(rs, key=lambda r: [int(x) for x in r.rsplit(".", 1)[-1].split("-")[1:]])[-1])')
udid=$(xcrun simctl list --json devices | /usr/bin/python3 -c "import json,sys; ds=json.load(sys.stdin)['devices'].get('$runtime',[]); print(next(d['udid'] for d in ds if d['name']=='{device}'))")
xcrun simctl bootstatus "$udid" -b >/dev/null
export SIMCTL_CHILD_TZ="$TZ"
if [[ -n "$frameworks" ]]; then export SIMCTL_CHILD_DYLD_FRAMEWORK_PATH="$frameworks"; fi
exec xcrun simctl spawn --standalone "$udid" "$bin" "$@"
"""

_HOST_RUNNER = """#!/usr/bin/env bash
set -euo pipefail
{setup}
if [[ -n "$frameworks" ]]; then export DYLD_FRAMEWORK_PATH="$frameworks"; fi
exec "$bin" "$@"
"""

# The binary runs from its own directory; with resources (see kmp_native_test.data) it runs from a
# copy next to them, as the binary resolves NSBundle.mainBundle through its real path.
_RUNNER_SETUP = """bin="$PWD/{binary}"
# As for JVM tests: cached results must not depend on the host's time zone or locale.
export TZ=UTC LANG=en_US.UTF-8
frameworks="{frameworks}"
resources="$PWD/{resources}"
if [[ -d "$resources" ]]; then
  dir="${{TEST_TMPDIR:-$(mktemp -d)}}/bin"
  rm -rf "$dir" && mkdir -p "$dir"
  cp -RL "$resources/." "$dir/"
  cp "$bin" "$dir/" && bin="$dir/$(basename "$bin")"
fi
cd "$(dirname "$bin")"
"""

# Test resources Gradle's ios-simulator-tests plugin copies next to the test binary.
_RESOURCES_DIR = "/src/commonTest/resources/"

def _compose_resource_paths(info):
    """Compose resources as {compose-resources/composeResources/<package>/<file>: File}.

    Compose Multiplatform reads them from there, relative to the main bundle's resource directory.
    """
    paths = {}
    for r in info.transitive.to_list():
        for f in r.files:
            rel = f.path[len(r.root) + 1:] if f.path.startswith(r.root + "/") else f.basename
            paths["compose-resources/composeResources/%s/%s" % (r.package, rel)] = f
    return paths

def _kmp_native_test_impl(ctx):
    tc = kotlin_toolchain_info(ctx, NATIVE_TOOLCHAIN_TYPE)
    target = ctx.attr.target
    test = ctx.attr.test_klib[KlibInfo]
    libraries = test.transitive_klibs.to_list()
    include = [k for k in test.klibs if k.basename.endswith(".klib")][:1]
    libraries = [l for l in libraries if l not in include]
    out = ctx.actions.declare_file(ctx.label.name + ".kexe")
    link = _native_link(ctx, [test])
    caches = link_caches(ctx, tc, target, [ctx.attr.test_klib[NativeCacheInfo].dep_caches], release = False)
    args = _link_args(
        ctx,
        tc,
        target,
        "program",
        out.path[:-len(".kexe")],
        include,
        libraries,
        link.linkopts,
        extra = ["-generate-test-runner", "-g", "-Xbinary=bundleId=" + ctx.attr.bundle_id_prefix + ctx.label.name.replace("-", "_")] + caches.compiler_args,
    )
    _run_link(ctx, tc, target, args, include + libraries + link.inputs, [out], "KotlinNativeLink", "Linking Kotlin/Native test %{label}", caches)

    resources_dir = ctx.label.name + ".resources"
    symlinks = {}
    for f in ctx.files.data:
        if _RESOURCES_DIR in "/" + f.short_path:
            rel = ("/" + f.short_path).split(_RESOURCES_DIR, 1)[1]
            symlinks["%s/%s/%s" % (ctx.label.package, resources_dir, rel)] = f
    if ComposeResourcesInfo in ctx.attr.test_klib:
        for path, f in _compose_resource_paths(ctx.attr.test_klib[ComposeResourcesInfo]).items():
            symlinks["%s/%s/%s" % (ctx.label.package, resources_dir, path)] = f
    runner = ctx.actions.declare_file(ctx.label.name + ".sh")
    template = _SIM_RUNNER if target in ("ios_simulator_arm64", "ios_x64") else _HOST_RUNNER
    setup = _RUNNER_SETUP.format(
        binary = out.short_path,
        frameworks = ":".join(["$PWD/" + d for d in _framework_dirs(link.runtime)]),
        resources = "%s/%s" % (ctx.label.package, resources_dir),
    )
    ctx.actions.write(runner, template.format(setup = setup, device = ctx.attr.device), is_executable = True)
    runfiles = ctx.runfiles(files = [out] + ctx.files.data + link.runtime)
    if symlinks:
        runfiles = runfiles.merge(ctx.runfiles(symlinks = symlinks))
    return [DefaultInfo(executable = runner, runfiles = runfiles)]

kmp_native_test = rule(
    implementation = _kmp_native_test_impl,
    test = True,
    doc = """A Kotlin/Native test executable, run on the host or on an iOS simulator.

Native libraries come from the test klib's dependencies (NativeLinkInfo of cinterop klibs); dynamic
frameworks are found through DYLD_FRAMEWORK_PATH. Compose resources and files under
src/commonTest/resources/ are placed next to the binary, where NSBundle.mainBundle finds them.""",
    attrs = {
        "test_klib": attr.label(providers = [KlibInfo], mandatory = True, aspects = [native_cache_aspect]),
        "target": attr.string(mandatory = True),
        "data": attr.label_list(allow_files = True, doc = "Runtime files; see the rule doc for test resources."),
        "linkopts": attr.string_list(),
        "link_inputs": attr.label_list(allow_files = True, doc = "Files or NativeLinkInfo targets to link."),
        "device": attr.string(default = "iPhone 17"),
        "bundle_id_prefix": attr.string(default = "test.", doc = "The binary's bundle id is this prefix and the target name."),
        "_xcode_config": attr.label(default = _XCODE_CONFIG),
        "_native_caches": attr.label(default = "//config:native_caches"),
        "_ios_minimum_os": IOS_MINIMUM_OS_ATTR,
        "_debug_transparent_stepping": DEBUG_TRANSPARENT_STEPPING_ATTR,
    },
    toolchains = [NATIVE_TOOLCHAIN_TYPE],
)

def _kmp_native_framework_impl(ctx):
    tc = kotlin_toolchain_info(ctx, NATIVE_TOOLCHAIN_TYPE)
    target = ctx.attr.target
    main = [d[KlibInfo] for d in ctx.attr.deps]
    exports = [d[KlibInfo] for d in ctx.attr.exports]
    libraries = depset(transitive = [d.transitive_klibs for d in main + exports], order = "postorder").to_list()
    include = [k for d in main for k in d.klibs[:1]]
    libraries = [l for l in libraries if l not in include]
    base = ctx.attr.base_name
    fw_dir = "%s/%s.framework" % (ctx.label.name, base)
    if ctx.attr.static:
        # Declared file by file so that rules_apple can import the framework into an app.
        outputs = [ctx.actions.declare_file(fw_dir + "/" + f) for f in [
            base,
            "Headers/%s.h" % base,
            "Info.plist",
            "Modules/module.modulemap",
        ]]
        out_dir = outputs[0].dirname.rsplit("/", 1)[0]
    else:
        outputs = [ctx.actions.declare_directory(fw_dir)]
        out_dir = outputs[0].dirname
    extra = ["-Xbinary=bundleId=" + ctx.attr.bundle_id] if ctx.attr.bundle_id else []
    if ctx.attr.static:
        extra.append("-Xstatic-framework")
    extra.append("-opt" if ctx.attr.release else "-g")
    for e in exports:
        for k in e.klibs[:1]:
            extra.append("-Xexport-library=" + k.path)
    extra.extend(ctx.attr.kotlinc_opts)
    # A static framework is an archive of the Kotlin code only; the app links the native libraries.
    link = _native_link(ctx, main + exports) if not ctx.attr.static else struct(linkopts = [], inputs = [])
    caches = link_caches(
        ctx,
        tc,
        target,
        [d[NativeCacheInfo].dep_caches for d in ctx.attr.deps] + [d[NativeCacheInfo].caches for d in ctx.attr.exports],
        release = ctx.attr.release,
    )
    args = _link_args(ctx, tc, target, "framework", out_dir + "/" + base, include, libraries, link.linkopts, extra + caches.compiler_args)
    _run_link(ctx, tc, target, args, include + libraries + link.inputs, outputs, "KotlinNativeLink", "Linking Kotlin/Native framework %{label}", caches)

    resources = []
    compose = [d[ComposeResourcesInfo] for d in ctx.attr.deps + ctx.attr.exports if ComposeResourcesInfo in d]
    if compose:
        merged = ComposeResourcesInfo(transitive = depset(transitive = [c.transitive for c in compose]))
        for path, f in _compose_resource_paths(merged).items():
            out = ctx.actions.declare_file("%s_resources/%s" % (ctx.label.name, path))
            ctx.actions.symlink(output = out, target_file = f)
            resources.append(out)
    return [
        DefaultInfo(files = depset(outputs)),
        OutputGroupInfo(compose_resources = depset(resources)),
    ]

kmp_native_framework = rule(
    implementation = _kmp_native_framework_impl,
    doc = """An Apple framework of Kotlin/Native code, as the CocoaPods Gradle plugin builds it.

Static frameworks contain the Kotlin code only; the app links the native libraries (CocoaPods).
The compose_resources output group holds the Compose resources the app bundles under
compose-resources/.""",
    attrs = {
        "base_name": attr.string(mandatory = True),
        "target": attr.string(mandatory = True),
        "deps": attr.label_list(providers = [KlibInfo], aspects = [native_cache_aspect], doc = "Libraries included in the framework."),
        "exports": attr.label_list(providers = [KlibInfo], aspects = [native_cache_aspect], doc = "Libraries whose API the framework exports."),
        "static": attr.bool(default = True),
        "release": attr.bool(default = False),
        "bundle_id": attr.string(),
        "linkopts": attr.string_list(),
        "link_inputs": attr.label_list(allow_files = True),
        "kotlinc_opts": attr.string_list(),
        "_xcode_config": attr.label(default = _XCODE_CONFIG),
        "_native_caches": attr.label(default = "//config:native_caches"),
        "_ios_minimum_os": IOS_MINIMUM_OS_ATTR,
        "_debug_transparent_stepping": DEBUG_TRANSPARENT_STEPPING_ATTR,
    },
    toolchains = [NATIVE_TOOLCHAIN_TYPE],
)
