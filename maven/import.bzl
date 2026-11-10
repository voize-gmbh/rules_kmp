"""Rules wrapping pinned Maven artifacts (see extension.bzl)."""

load("@rules_android//android:rules.bzl", "aar_import", "android_library")
load("@rules_java//java/common:java_common.bzl", "java_common")
load("@rules_java//java/common:java_info.bzl", "JavaInfo")
load("//android:android.bzl", "EMPTY_MANIFEST", "GENERATED_PACKAGE")
load("//kotlin:providers.bzl", "KlibInfo", "NativeLinkInfo")

def _maven_jar_impl(ctx):
    deps = [d[JavaInfo] for d in ctx.attr.deps]
    runtime_deps = [d[JavaInfo] for d in ctx.attr.runtime_deps]
    infos = []
    compile_jars = ctx.files.compile_jars
    if compile_jars and len(compile_jars) != len(ctx.files.jars):
        fail("compile_jars must pair up with jars")
    for i, jar in enumerate(ctx.files.jars):
        # The full jar doubles as the compile jar: ijar would drop Kotlin inline function bodies.
        infos.append(JavaInfo(
            output_jar = jar,
            compile_jar = compile_jars[i] if compile_jars else jar,
            deps = deps,
            runtime_deps = runtime_deps,
            # The lock's deps are what Gradle puts on a consumer's compile classpath (POM compile
            # scope, Gradle metadata apiElements).
            exports = deps,
        ))
    if not infos:
        # A Gradle-metadata root module (e.g. kotlinx-coroutines-core) that only points at its
        # platform artifact: forward its dependencies.
        info = java_common.merge(deps + runtime_deps) if (deps or runtime_deps) else None
        if info == None:
            return [DefaultInfo(), JavaInfo(output_jar = ctx.file._empty_jar, compile_jar = ctx.file._empty_jar)]
        return [DefaultInfo(), info]
    return [
        DefaultInfo(files = depset(ctx.files.jars)),
        java_common.merge(infos) if len(infos) > 1 else infos[0],
    ]

_AVAILABLE_AT = attr.string(doc = "group:artifact:version of the platform module a Kotlin Multiplatform root module points to.")

maven_jar = rule(
    implementation = _maven_jar_impl,
    attrs = {
        "coordinates": attr.string(),
        "available_at": _AVAILABLE_AT,
        "jars": attr.label_list(allow_files = [".jar"]),
        "compile_jars": attr.label_list(
            allow_files = [".jar"],
            doc = "Jars to compile against when Gradle compiles against a lower version than it runs with.",
        ),
        "deps": attr.label_list(providers = [JavaInfo]),
        "runtime_deps": attr.label_list(providers = [JavaInfo]),
        "_empty_jar": attr.label(default = "//maven:empty.jar", allow_single_file = True),
    },
    provides = [JavaInfo],
)

def maven_aar(name, coordinates, aar, jars = [], deps = [], runtime_deps = [], **kwargs):
    """An Android archive; runtime dependencies are packaged with it, so they become deps.

    The android_library wrapper exports the compile-scope deps too (aar_import can only export other
    imports), so a consumer compiles against what Gradle would put on its classpath.
    """
    aar_import(
        name = name + "_aar",
        aar = aar,
        deps = deps + runtime_deps,
        tags = ["maven_coordinates=" + coordinates],
        **kwargs
    )
    android_library(
        name = name,
        exports = [":" + name + "_aar"] + deps,
        **kwargs
    )

def _maven_klib_impl(ctx):
    deps = [d[KlibInfo] for d in ctx.attr.deps]
    links = [t[NativeLinkInfo] for t in ctx.attr.link_inputs]
    return [
        DefaultInfo(files = depset(ctx.files.klibs)),
        KlibInfo(
            target = ctx.attr.target,
            klibs = ctx.files.klibs,
            transitive_klibs = depset(ctx.files.klibs, transitive = [d.transitive_klibs for d in deps], order = "postorder"),
            header_klibs = ctx.files.klibs,
            compile_klibs = depset(ctx.files.klibs, transitive = [d.compile_klibs for d in deps], order = "postorder"),
            module_name = None,
            native_linkopts = depset(transitive = [d.native_linkopts for d in deps] + [l.linkopts for l in links]),
            native_link_inputs = depset(transitive = [d.native_link_inputs for d in deps] + [l.inputs for l in links]),
            native_runtime_files = depset(transitive = [getattr(d, "native_runtime_files", None) or depset() for d in deps] + [l.runtime_files for l in links]),
            resources = depset(transitive = [d.resources for d in deps]),
        ),
    ]

maven_klib = rule(
    implementation = _maven_klib_impl,
    attrs = {
        "coordinates": attr.string(),
        "available_at": _AVAILABLE_AT,
        "klibs": attr.label_list(allow_files = [".klib"]),
        "deps": attr.label_list(providers = [KlibInfo]),
        "link_inputs": attr.label_list(
            providers = [NativeLinkInfo],
            doc = "Frameworks the klibs' linkerOpts ask for (maven_lock.json link_pods).",
        ),
        "target": attr.string(mandatory = True),
    },
    provides = [KlibInfo],
)

def maven_android_library(name, exports, deps = [], **kwargs):
    """Forwards a module's dependencies as an android_library (see extension.bzl).

    Args:
      name: Target name.
      exports: The jar and compile-scope dependencies: a consumer compiles against these.
      deps: Runtime-scope dependencies: packaged with the app, but not on a compile classpath.
      **kwargs: Other android_library attributes.
    """
    android_library(
        name = name,
        exports = exports,
        deps = deps,
        manifest = EMPTY_MANIFEST,
        # Has no resources of its own, but R class generation needs a package for every library.
        custom_package = GENERATED_PACKAGE,
        **kwargs
    )
