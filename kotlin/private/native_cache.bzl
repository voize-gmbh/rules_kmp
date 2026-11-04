"""Kotlin/Native static caches: each library compiled to native code once, for debug links.

Linking a debug binary otherwise compiles every library it contains, every time. The aspect gives
each klib its own cache action, so a library is cached once per target platform, shared by every
binary that links it and by the remote cache, and an edit only recompiles what changed. Release
binaries don't use caches. A library can only be cached if everything it depends on is; one that
isn't (`cacheable = False`, or below one) is compiled into the binary as before.
"""

load("@bazel_skylib//rules:common_settings.bzl", "BuildSettingInfo")
load("//apple:transitions.bzl", "APPLE_TARGETS")
load("//kotlin:providers.bzl", "KlibInfo", "NativeCacheInfo")
load(":compile.bzl", "native_env", "native_sysprops")
load(":toolchain.bzl", "NATIVE_CACHE_TOOLCHAIN_TYPE", "kotlin_toolchain_info")

_DEP_ATTRS = ["deps", "exports", "runtime_deps", "friends", "cinterop_klibs", "libraries"]

# Attribute for konan_properties' ios_minimum_os.
IOS_MINIMUM_OS_ATTR = attr.label(default = "//config:ios_minimum_os", providers = [BuildSettingInfo])

# Attribute for debug_stepping_args.
DEBUG_TRANSPARENT_STEPPING_ATTR = attr.label(default = "//config:debug_transparent_stepping", providers = [BuildSettingInfo])

def debug_stepping_args(tc, stepping):
    """Turns off debug info for transparent stepping unless the flag asks for it.

    Only Apple's LLVM produces it (Kotlin/Native's LLVM for other hosts aborts on it), so caches
    compiled on Linux never have it; without it on a Mac too, caches and links match theirs.

    Args:
      tc: The Kotlin toolchain.
      stepping: The target of DEBUG_TRANSPARENT_STEPPING_ATTR.

    Returns:
      Compiler arguments.
    """
    if tc.native_xcode and stepping[BuildSettingInfo].value:
        return []
    return ["-Xbinary=enableDebugTransparentStepping=false"]

def konan_properties(target, ios_minimum_os):
    """-Xoverride-konan-properties for linking and caching: both must compile alike.

    Args:
      target: Kotlin/Native target.
      ios_minimum_os: The target of IOS_MINIMUM_OS_ATTR.

    Returns:
      The compiler argument.
    """
    props = ["airplaneMode=true"]
    if target in APPLE_TARGETS:
        props.append("osVersionMin.%s=%s" % (target, ios_minimum_os[BuildSettingInfo].value))
    if target.startswith("macos_"):
        # The only listed dependency is the debugger the distribution bundles for macOS hosts;
        # compiling never runs it.
        props.append("dependencies.%s=" % target)
    return "-Xoverride-konan-properties=" + ";".join(props)

def _native_cache_aspect_impl(target, ctx):
    deps = [d for a in _DEP_ATTRS for d in getattr(ctx.rule.attr, a, []) if NativeCacheInfo in d]
    dep_caches = depset(transitive = [d[NativeCacheInfo].caches for d in deps])
    dep_external = depset(transitive = [d[NativeCacheInfo].external_caches for d in deps])
    dep_abi = depset(transitive = [d[NativeCacheInfo].abi_caches for d in deps])
    uncached = NativeCacheInfo(cached = False, caches = dep_caches, dep_caches = dep_caches, external_caches = dep_external, abi_caches = dep_abi)
    if KlibInfo not in target:
        return [uncached]
    info = target[KlibInfo]
    tc = kotlin_toolchain_info(ctx, NATIVE_CACHE_TOOLCHAIN_TYPE)
    system = tc.native_system_caches.get(info.target)
    if (not system or not ctx.attr._enabled[BuildSettingInfo].value or
        not getattr(ctx.rule.attr, "cacheable", True) or
        not all([d[NativeCacheInfo].cached for d in deps])):
        return [uncached]
    dep_klibs = {k: True for d in deps if KlibInfo in d for k in d[KlibInfo].klibs}
    own = [k for k in info.klibs if k not in dep_klibs]
    if not own:
        return [NativeCacheInfo(cached = True, caches = dep_caches, dep_caches = dep_caches, external_caches = dep_external, abi_caches = dep_abi)]

    out = ctx.actions.declare_directory(ctx.label.name + ".kncache")
    abi = ctx.actions.declare_directory(ctx.label.name + ".kncache_abi")

    # Built against what its code generation reads from dependencies (header klibs and cache
    # metadata), so an unchanged ABI below doesn't rebuild it. Friends' internals are only in
    # their full klibs.
    own_headers = {h: True for k, h in zip(info.klibs, info.header_klibs) if k in own}
    friends = [f[KlibInfo] for f in getattr(ctx.rule.attr, "friends", []) if KlibInfo in f]
    friend_headers = {h: True for f in friends for h in f.header_klibs}
    libraries = [
        k
        for k in info.compile_klibs.to_list()
        if k not in own_headers and k not in friend_headers
    ] + [k for f in friends for k in f.klibs]
    args = ctx.actions.args()
    args.set_param_file_format("multiline")
    args.use_param_file("@%s", use_always = True)
    args.add("--mode", "native_cache")
    args.add("--tmp_dir", out.path + ".tmp")
    args.add("--compiler_main", "org.jetbrains.kotlin.cli.bc.K2Native")
    args.add_all(tc.native_compiler_classpath, before_each = "--compiler_classpath")
    for p in native_sysprops(tc):
        args.add("--sysprop", p)
    args.add("--output", out.path)
    args.add("--abi_output", abi.path)
    # Links run on a Mac whichever host built the cache.
    args.add("--cache_host", "macos_arm64")
    args.add_all(own, before_each = "--cache_klib")
    args.add_all(dep_abi, before_each = "--cache_dir", expand_directories = False)
    args.add("--")
    args.add("-target", info.target)
    args.add("-produce", "static_cache")
    args.add("-g")
    args.add(konan_properties(info.target, ctx.attr._ios_minimum_os))
    args.add("-Xkonan-data-dir=" + tc.konan_data)
    args.add("-Xdebug-prefix-map=__EXECROOT__=.")
    # The compiler stubs out what it cannot resolve; with dependencies' header klibs that would be
    # a wrong cache instead of a failed one. Maven klibs keep the default: they are built against
    # full klibs, and some call into other versions of their dependencies than we resolve.
    if ctx.rule.kind != "maven_klib":
        args.add("-Xpartial-linkage-loglevel=error")
    args.add("-Xcache-directory=" + system.dir)
    args.add_all(tc.native_apple_args)
    args.add_all(debug_stepping_args(tc, ctx.attr._debug_transparent_stepping))
    args.add_all(libraries, before_each = "-library")
    requirements = {
        "supports-workers": "1",
        "worker-key-mnemonic": "KotlinNativeCache",
    }
    if tc.native_xcode:
        requirements["requires-darwin"] = "1"
    ctx.actions.run(
        mnemonic = "KotlinNativeCache",
        progress_message = "Caching Kotlin/Native library %{label} (" + info.target + ")",
        executable = tc.builder,
        arguments = [args],
        inputs = depset(own + libraries, transitive = [dep_abi, system.files, tc.native_target_files[info.target], tc.native_deps_files]),
        tools = depset(tc.native_compiler_classpath, transitive = [tc.native_apple_toolchain]),
        outputs = [out, abi],
        # Apple's libtool stores timestamps in archives otherwise.
        env = (native_env(ctx, info.target) | {"ZERO_AR_DATE": "1"}) if tc.native_xcode else {},
        execution_requirements = requirements,
    )
    caches = depset([out], transitive = [dep_caches])
    external = depset([out] if ctx.rule.kind == "maven_klib" else [], transitive = [dep_external])
    return [NativeCacheInfo(cached = True, caches = caches, dep_caches = dep_caches, external_caches = external, abi_caches = depset([abi], transitive = [dep_abi]))]

native_cache_aspect = aspect(
    implementation = _native_cache_aspect_impl,
    attr_aspects = _DEP_ATTRS,
    attrs = {
        "_xcode_config": attr.label(default = "@apple_support//xcode:version_config"),
        "_enabled": attr.label(default = "//config:native_caches"),
        "_ios_minimum_os": IOS_MINIMUM_OS_ATTR,
        "_debug_transparent_stepping": DEBUG_TRANSPARENT_STEPPING_ATTR,
    },
    provides = [NativeCacheInfo],
    toolchains = [NATIVE_CACHE_TOOLCHAIN_TYPE],
)

def link_caches(ctx, tc, target, infos, release):
    """The caches a link uses: builder arguments, compiler arguments and inputs.

    `infos` are depsets of cache directories (see NativeCacheInfo).
    """
    system = tc.native_system_caches.get(target)
    if release or not system or not ctx.attr._native_caches[BuildSettingInfo].value:
        return struct(builder_args = [], compiler_args = [], inputs = depset())
    caches = depset(transitive = infos)
    builder_args = ctx.actions.args()
    builder_args.add_all(caches, before_each = "--cache_dir", expand_directories = False)
    return struct(
        builder_args = [builder_args],
        compiler_args = ["-Xcache-directory=" + system.dir],
        inputs = depset(transitive = [caches, system.files]),
    )
