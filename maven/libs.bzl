"""The libraries rules_kmp's toolchains and JVM test runner take from the Maven hub.

The maven extension generates them as @kmp_maven_libs, so the default toolchains share the
hub's kotlin-stdlib with the libraries that depend on it instead of adding a second copy.
"""

def _missing_impl(ctx):
    fail(ctx.attr.message)

missing = rule(
    implementation = _missing_impl,
    doc = "Fails the build of whatever depends on it with `message`.",
    attrs = {"message": attr.string(mandatory = True)},
)

# defs.bzl name -> (lock platform, group:module); None in defs.bzl without it.
_OPTIONAL = {
    "JVM_STDLIB": ("jvm", "org.jetbrains.kotlin:kotlin-stdlib"),
    "ANDROID_STDLIB": ("android", "org.jetbrains.kotlin:kotlin-stdlib"),
}

# Target name -> (lock platform, group:module); only web compilations need them.
_ALIASES = {
    "js_stdlib": ("js", "org.jetbrains.kotlin:kotlin-stdlib-js"),
    "wasm_js_stdlib": ("wasm_js", "org.jetbrains.kotlin:kotlin-stdlib-wasm-js"),
    "js_test": ("js", "org.jetbrains.kotlin:kotlin-test-js"),
    "wasm_js_test": ("wasm_js", "org.jetbrains.kotlin:kotlin-test-wasm-js"),
}

# KSP2's command-line classpath; the first is what makes KSP available.
_KSP = [
    "com.google.devtools.ksp:symbol-processing-aa-embeddable",
    "com.google.devtools.ksp:symbol-processing-api",
    "com.google.devtools.ksp:symbol-processing-common-deps",
    "org.jetbrains.kotlin:kotlin-stdlib",
    "org.jetbrains.kotlinx:kotlinx-coroutines-core-jvm",
]

_JUNIT_PLATFORM = [
    "org.junit.platform:junit-platform-launcher",
    "org.junit.platform:junit-platform-commons",
    "org.junit.platform:junit-platform-engine",
]

def _name(coordinate):
    return "".join([c if (c.isalnum() or c == "_") else "_" for c in coordinate.elems()])

def _label(hub, platform, coordinate):
    return "@%s//%s:%s" % (hub, platform, _name(coordinate))

def _maven_libs_impl(rctx):
    hub = rctx.attr.hub
    present = {k: True for k in rctx.attr.modules}

    def has(platform, coordinate):
        return hub and ("%s %s" % (platform, coordinate)) in present

    lines = [
        'load("%s", "missing")' % Label("//maven:libs.bzl"),
        'load("@rules_java//java:java_library.bzl", "java_library")',
        "",
        'package(default_visibility = ["//visibility:public"])',
        "",
    ]
    for name, (platform, coordinate) in _ALIASES.items():
        if has(platform, coordinate):
            lines.append('alias(name = "%s", actual = "%s")' % (name, _label(hub, platform, coordinate)))
        else:
            lines.append('missing(name = "%s", message = %r)' % (
                name,
                "The Kotlin toolchains take %s from the Maven hub: add maven.artifact(\"%s:<version>\", platforms = [\"%s\"])." % (coordinate, coordinate, platform),
            ))

    defs = {}
    for name, (platform, coordinate) in _OPTIONAL.items():
        defs[name] = None
        if has(platform, coordinate):
            lines.append('alias(name = "%s", actual = "%s")' % (name.lower(), _label(hub, platform, coordinate)))
            defs[name] = name.lower()

    ksp = has("tools", _KSP[0])
    defs["KSP"] = "ksp" if ksp else None
    if ksp:
        lines.append('java_library(name = "ksp", runtime_deps = %r)' % [
            _label(hub, "tools", c)
            for c in _KSP
            if has("tools", c)
        ])

    if all([has("jvm", c) for c in _JUNIT_PLATFORM]):
        lines.append('java_library(name = "junit_launcher_api", neverlink = True, exports = [%r])' % _label(hub, "jvm", _JUNIT_PLATFORM[0]))
        lines.append('java_library(name = "junit_runner", srcs = [%r], deps = [":junit_launcher_api", %r, %r])' % (
            str(rctx.attr.runner_src),
            _label(hub, "jvm", _JUNIT_PLATFORM[1]),
            _label(hub, "jvm", _JUNIT_PLATFORM[2]),
        ))
        runtime = [":junit_runner"]
        for c in ["org.junit.jupiter:junit-jupiter-engine", _JUNIT_PLATFORM[0], "org.junit.vintage:junit-vintage-engine"]:
            if has("jvm", c):
                runtime.append(_label(hub, "jvm", c))
        lines.append('java_library(name = "jvm_test_runner", runtime_deps = %r)' % runtime)
    else:
        lines.append('missing(name = "jvm_test_runner", message = %r)' % (
            "JVM tests need the JUnit Platform from the Maven hub: add maven.artifact entries for %s on the jvm platform, or set kmp_conventions(jvm_test_runner)." % ", ".join(_JUNIT_PLATFORM),
        ))

    rctx.file("BUILD.bazel", "\n".join(lines) + "\n")
    rctx.file("defs.bzl", "".join([
        "%s = %s\n" % (name, 'Label("//:%s")' % target if target else "None")
        for name, target in sorted(defs.items())
    ]))
    return rctx.repo_metadata(reproducible = True)

maven_libs_repository = repository_rule(
    implementation = _maven_libs_impl,
    attrs = {
        "hub": attr.string(doc = "The hub repository; empty without a maven.lock."),
        "modules": attr.string_list(doc = "\"<platform> <group:module>\" of every module in the lock."),
        "runner_src": attr.label(default = "//kotlin/testing:BazelJUnitRunner.java"),
    },
)
