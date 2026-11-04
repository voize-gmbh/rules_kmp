"""Turns Objective-C/Swift targets (CcInfo, SwiftInfo) into what Kotlin/Native needs from them.

cinterop needs clang flags to find their headers and module maps; linking a Kotlin/Native
executable needs their archives, frameworks and linker flags, passed to ld by the Kotlin/Native
compiler as -linker-option values.
"""

load("@rules_cc//cc/common:cc_common.bzl", "cc_common")
load("@rules_cc//cc/common:cc_info.bzl", "CcInfo")
load("@rules_swift//swift:providers.bzl", "SwiftInfo")
load("//kotlin:providers.bzl", "NativeLinkInfo")
load(":transitions.bzl", "apple_target_transition")

# Attribute for apple_link_info's swift_runtime.
SWIFT_RUNTIME_ATTR = attr.label(
    default = "//apple:swift_runtime_libs",
    cfg = apple_target_transition,
)

# ld flags whose value is the next argument.
_FLAGS_WITH_VALUE = ["-framework", "-weak_framework", "-needed_framework", "-rpath", "-u", "-force_load"]

def apple_compile_info(targets):
    """clang flags and input files to parse the headers of `targets`.

    Args:
      targets: Targets providing CcInfo and/or SwiftInfo, built for the Apple platform.

    Returns:
      struct(opts = list[str], inputs = depset[File]).
    """
    opts = []
    transitive = []
    direct = []
    for t in targets:
        if CcInfo not in t:
            continue
        cc = t[CcInfo].compilation_context
        transitive.append(cc.headers)
        for d in cc.includes.to_list():
            opts.append("-I" + d)
        for d in cc.quote_includes.to_list():
            opts.append("-iquote" + d)
        for d in cc.system_includes.to_list():
            opts.append("-isystem" + d)
        for d in cc.framework_includes.to_list():
            opts.append("-F" + d)
        for d in cc.defines.to_list():
            opts.append("-D" + d)
    for t in targets:
        if SwiftInfo not in t:
            continue
        for m in t[SwiftInfo].transitive_modules.to_list():
            if not m.clang or not m.clang.module_map or type(m.clang.module_map) == "string":
                continue
            opts.append("-fmodule-map-file=" + m.clang.module_map.path)
            direct.append(m.clang.module_map)
            transitive.append(m.clang.compilation_context.headers)
    return struct(opts = _dedup(opts), inputs = depset(direct, transitive = transitive))

def apple_link_info(targets, swift_runtime, extra_linkopts = []):
    """NativeLinkInfo for linking `targets` into a Kotlin/Native executable.

    Args:
      targets: Targets providing CcInfo, built for the Apple platform.
      swift_runtime: The apple_swift_runtime_libs target for the same platform (as a list of one,
        from a transitioned attribute).
      extra_linkopts: Additional linker flags.

    Returns:
      NativeLinkInfo.
    """
    runtime_libs = swift_runtime[0][DefaultInfo].files.to_list()
    cc = cc_common.merge_cc_infos(cc_infos = [t[CcInfo] for t in targets if CcInfo in t])
    linkopts = []
    inputs = []
    runtime = []
    for li in cc.linking_context.linker_inputs.to_list():
        for lib in li.libraries:
            static = lib.static_library or lib.pic_static_library
            binary = static or lib.resolved_symlink_dynamic_library or lib.dynamic_library
            if not binary:
                continue
            if not static:
                runtime.append(binary)
            inputs.append(binary)
            if lib.alwayslink:
                linkopts.append("-force_load " + binary.path)
            elif binary.dirname.endswith("/%s.framework" % binary.basename):
                # By name, as klibs can name it too (sentry-kotlin-multiplatform: -framework Sentry);
                # ld would load the archive twice if it also came by path.
                linkopts.append("-F" + binary.dirname.rsplit("/", 1)[0])
                linkopts.append("-framework " + binary.basename)
            else:
                linkopts.append(binary.path)
        for f in _ld_flags(li.user_link_flags):
            f = _resolve_xcode_paths(f, runtime_libs)
            if f:
                linkopts.append(f)
        inputs.extend(li.additional_inputs)
    if any([f.startswith("-L" + runtime_libs[0].dirname) for f in linkopts]):
        inputs.extend(runtime_libs)
    linkopts.extend(extra_linkopts)
    return NativeLinkInfo(
        linkopts = depset(_dedup(linkopts)),
        inputs = depset(inputs),
        runtime_files = depset(runtime),
    )

_DEVELOPER_DIR = "__BAZEL_XCODE_DEVELOPER_DIR__"
_SDKROOT = "__BAZEL_XCODE_SDKROOT__"

def _resolve_xcode_paths(flag, runtime_libs):
    """Rewrites Xcode path placeholders, which only Bazel's C++/Swift toolchains substitute.

    The SDK is Kotlin/Native's ld -syslibroot, so SDK paths become absolute paths under it. The
    toolchain's Swift libraries come from apple_swift_runtime_libs. Paths into Xcode's platform
    directory (XCTest) are dropped.
    """
    if _SDKROOT in flag:
        return flag.replace(_SDKROOT, "")
    if _DEVELOPER_DIR not in flag:
        return flag
    if "/usr/lib/swift/" in flag and flag.startswith("-L"):
        return "-L" + runtime_libs[0].dirname
    return None

def _ld_flags(flags):
    """clang driver link flags -> ld flags, a flag and its value joined by a space."""
    out = []
    pending = None
    for f in flags:
        if pending:
            out.append(pending + " " + f)
            pending = None
            continue
        if f in _FLAGS_WITH_VALUE:
            pending = f
        elif f.startswith("-Wl,"):
            parts = f[len("-Wl,"):].split(",")
            out.append(" ".join(parts))
        elif f == "-fobjc-link-runtime" or f.startswith("-fobjc-arc"):
            # clang driver flags; Kotlin/Native links the Objective-C runtime itself.
            continue
        else:
            out.append(f)
    return out

def _dedup(items):
    out = []
    seen = {}
    for i in items:
        if i not in seen:
            seen[i] = True
            out.append(i)
    return out

def _apple_native_libs_impl(ctx):
    return [apple_link_info(ctx.attr.deps, ctx.attr._swift_runtime, ctx.attr.linkopts)]

apple_native_libs = rule(
    implementation = _apple_native_libs_impl,
    doc = """Objective-C/Swift libraries built for one Kotlin/Native Apple target, for linking.

Use as a link input of a Kotlin/Native library or test (native_options(link_inputs=...)), e.g. for
CocoaPods a module links without generating bindings for them (Gradle's linkOnly pods).""",
    attrs = {
        "target": attr.string(mandatory = True, doc = "Kotlin/Native target, e.g. ios_simulator_arm64."),
        "deps": attr.label_list(cfg = apple_target_transition, providers = [[CcInfo]]),
        "linkopts": attr.string_list(),
        "_swift_runtime": SWIFT_RUNTIME_ATTR,
    },
    provides = [NativeLinkInfo],
)

_SWIFT_RUNTIME_LIBS = [
    "libswiftCompatibility50.a",
    "libswiftCompatibility51.a",
    "libswiftCompatibility56.a",
    "libswiftCompatibilityConcurrency.a",
    "libswiftCompatibilityDynamicReplacements.a",
    "libswiftCompatibilityPacks.a",
]

def _apple_swift_runtime_libs_impl(ctx):
    xcode = ctx.attr._xcode_config[apple_common.XcodeVersionConfig]
    platform = ctx.fragments.apple.single_arch_platform
    outs = [ctx.actions.declare_file("%s/%s" % (ctx.label.name, f)) for f in _SWIFT_RUNTIME_LIBS]
    env = dict(apple_common.apple_host_system_env(xcode))
    env.update(apple_common.target_apple_env(xcode, platform))
    requirements = {"requires-darwin": "1"}
    requirements.update(xcode.execution_info())
    ctx.actions.run_shell(
        mnemonic = "SwiftRuntimeLibs",
        progress_message = "Copying Swift back-deployment libraries of Xcode %{label}",
        command = 'cp "$DEVELOPER_DIR/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/%s/"{%s} "%s/"' % (
            platform.name_in_plist.lower(),
            ",".join(_SWIFT_RUNTIME_LIBS),
            outs[0].dirname,
        ),
        outputs = outs,
        env = env,
        execution_requirements = requirements,
    )
    return [DefaultInfo(files = depset(outs))]

apple_swift_runtime_libs = rule(
    implementation = _apple_swift_runtime_libs_impl,
    doc = """Xcode's Swift back-deployment libraries (libswiftCompatibility*.a) for the target platform.

Swift code built for an older OS than the SDK references them; Bazel's linker toolchain finds them
in Xcode, Kotlin/Native's linker gets them from here.""",
    attrs = {
        "_xcode_config": attr.label(default = "@apple_support//xcode:version_config"),
    },
    fragments = ["apple"],
    exec_compatible_with = ["@platforms//os:macos"],
)

def _apple_framework_headers_impl(ctx):
    root = "%s/%s.framework" % (ctx.label.name, ctx.attr.framework)
    marker = "/%s/%s.framework/" % (ctx.attr.slice, ctx.attr.framework)
    outputs = []
    for f in ctx.files.srcs:
        if marker not in f.path or "/Headers/" not in f.path:
            continue
        out = ctx.actions.declare_file("%s/Headers/%s" % (root, f.path.split("/Headers/", 1)[1]))
        ctx.actions.symlink(output = out, target_file = f)
        outputs.append(out)
    module_map = ctx.actions.declare_file(root + "/Modules/module.modulemap")
    ctx.actions.write(module_map, ctx.attr.module_map)
    return [DefaultInfo(files = depset(outputs + [module_map]))]

apple_framework_headers = rule(
    implementation = _apple_framework_headers_impl,
    doc = """The headers of one XCFramework slice as a framework with its own module map.

For generating bindings from a different module than the one the framework declares.""",
    attrs = {
        "srcs": attr.label_list(allow_files = True, doc = "Files of the XCFramework."),
        "framework": attr.string(mandatory = True, doc = "Framework name, e.g. Sentry."),
        "slice": attr.string(mandatory = True, doc = "XCFramework library identifier, e.g. ios-arm64."),
        "module_map": attr.string(mandatory = True, doc = "Contents of Modules/module.modulemap."),
    },
)
