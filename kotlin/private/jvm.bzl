"""kmp_jvm_module: a plain Kotlin/JVM module (src/main, src/test, src/testFixtures)."""

load("@rules_android//android:rules.bzl", "android_library")
load("@rules_java//java:java_binary.bzl", "java_binary")
load(":compile.bzl", "kmp_jvm_library", "kmp_jvm_rewrap")
load(":conventions.bzl", "file_labels", "require")
load("//android:android.bzl", "EMPTY_MANIFEST", "GENERATED_PACKAGE")
load(":kmp.bzl", "maven_label", "test_options")
load("//maven:publication.bzl", "kmp_publication")
load(":testing.bzl", "kmp_jvm_tests")

def _jvm(labels, maven, platform = "jvm"):
    out = []
    for l in _dedupe(labels):
        if l.startswith(maven + "//:"):
            out.append("%s//%s:%s" % (maven, platform, l[len(maven + "//:"):]))
        elif l.startswith("@") or l.startswith("raw:"):
            out.append(l.removeprefix("raw:"))
        else:
            pkg, name = l.rsplit(":", 1) if ":" in l else (l, l.rsplit("/", 1)[-1])
            out.append("%s:%s_%s" % (pkg, name, platform))
    return out

def _dedupe(labels):
    out = []
    for l in labels:
        if l not in out:
            out.append(l)
    return out

def _srcs(dirs, excludes):
    files = []
    for d in dirs:
        files += native.glob([d + "/**/*.kt", d + "/**/*.java"], exclude = excludes, allow_empty = True)
    return {f: "main" for f in files}

def _resources(dirs, conventions):
    res = {}
    for d in dirs:
        for f in file_labels(conventions, native.glob([d + "/**"], allow_empty = True)):
            res[f] = native.package_name() + "/" + d + "/"
    return res

def kmp_jvm_module(
        name,
        module_name,
        conventions,
        deps = [],
        exports = [],
        compile_only = [],
        runtime_only = [],
        test_deps = [],
        test_compile_only = [],
        test_runtime_only = [],
        test_fixtures_deps = [],
        plugins = [],
        kotlinc_opts = [],
        opt_ins = [],
        srcjars = [],
        extra_srcs = [],
        src_dirs = ["src/main/kotlin", "src/main/java"],
        resource_dirs = ["src/main/resources"],
        test_src_dirs = ["src/test/kotlin", "src/test/java"],
        test_resource_dirs = ["src/test/resources"],
        test_fixtures = False,
        excludes = [],
        maven_platform = "jvm",
        classpath_first = {},
        maven_compile_versions = False,
        main_class = None,
        jvm_flags = [],
        test = None,
        publication = None,
        android_wrapper = False,
        on_compilation = None,
        visibility = None,
        tags = []):
    """Declares a Kotlin/JVM module laid out like Gradle's kotlin("jvm") projects.

    Creates `<name>_jvm` (aliased as `<name>`), `<name>_test`, optionally
    `<name>_testfixtures_jvm`, `<name>_bin` (a java_binary) when main_class is set, and with
    `android_wrapper` a manual `<name>_android` wrapper for Android consumers (only for modules
    Android code depends on: its deps resolve in the hub's android package).
    `maven_platform` selects the package of the hub repository (kmp_conventions(maven)) that
    third-party deps resolve to; for a platform of maven.lock(platforms), the module's targets and
    everything they depend on are built for it (see //maven:platform.bzl). `maven_compile_versions`
    is kmp_jvm_library's, for every compilation. `on_compilation` is called for the main and the
    test compilation, as for kmp_library. `publication` (publication_options()) declares
    `<name>_publication`, the module's Maven publication (see kmp_publication).
    """
    maven = conventions.maven
    _mvn = lambda labels: [l.replace(maven + "//jvm:", "%s//%s:" % (maven, maven_platform)) for l in _jvm(labels, maven)]
    if visibility == None:
        visibility = ["//visibility:public"]
    test = test or test_options()
    opts = ["-opt-in=" + o for o in opt_ins] + kotlinc_opts
    platform = {} if maven_platform == "jvm" else {"maven_platform": maven_platform}
    lib = name + "_jvm"
    kmp_jvm_library(
        name = lib,
        classpath_first = classpath_first.get("main", []),
        maven_compile_versions = maven_compile_versions,
        srcs = dict(_srcs(src_dirs, excludes), **{s: "main" for s in extra_srcs}),
        srcjars = {j: "main" for j in srcjars},
        fragments = ["main"],
        deps = _mvn(deps),
        exports = _mvn(exports),
        compile_only_deps = _mvn(compile_only),
        runtime_deps = _mvn(runtime_only),
        resources = _resources(resource_dirs, conventions),
        plugins = plugins,
        kotlinc_opts = opts,
        module_name = module_name,
        visibility = visibility,
        tags = tags,
        **platform
    )
    native.alias(name = name, actual = ":" + lib, visibility = visibility)
    if publication:
        kmp_publication(
            name = name + "_publication",
            coordinates = module_name,
            kind = "jvm",
            platforms = ["jvm"],
            artifacts = {":" + lib: "jvm"},
            srcs = {f: "jvm=" for f in _dedupe(
                list(_srcs(src_dirs, excludes).keys()) + extra_srcs + srcjars +
                # Gradle's sources jar takes everything in the source directories.
                native.glob([d + "/**" for d in src_dirs], exclude = excludes, allow_empty = True),
            )},
            api = {l: "jvm" for l in _mvn(exports)},
            implementation = {l: "jvm" for l in _mvn(deps)},
            runtime_only = {l: "jvm" for l in _mvn(runtime_only)},
            jars = publication.jars,
            pom_name = publication.name,
            pom_description = publication.description,
            visibility = visibility,
            tags = tags + ["manual"],
        )
    if on_compilation:
        on_compilation(struct(
            platform = "jvm",
            test = False,
            srcs = list(_srcs(src_dirs, excludes).keys()) + extra_srcs,
            srcjars = srcjars,
            compilation = ":" + lib,
            kotlinc_opts = opts,
        ))
    if android_wrapper:
        stdlib = maven_label(conventions, "android", "org_jetbrains_kotlin_kotlin_stdlib")
        android_deps = [d for d in _jvm(deps, maven, "android") if d != stdlib] + [stdlib]
        kmp_jvm_rewrap(
            name = name + "_android_jar",
            lib = ":" + lib,
            deps = android_deps,
            exports = _jvm(exports, maven, "android"),
            runtime_deps = _jvm(runtime_only, maven, "android"),
            visibility = visibility,
            tags = tags + ["manual"],
        )
        # Exports only the jar (and through it Gradle's api); the rest are deps so their resources
        # and native libraries still reach an app.
        android_library(
            name = name + "_android",
            exports = [":" + name + "_android_jar"],
            deps = android_deps + [d for d in _jvm(runtime_only, maven, "android") if d not in android_deps],
            manifest = EMPTY_MANIFEST,
            custom_package = GENERATED_PACKAGE,
            visibility = visibility,
            tags = tags + ["manual"],
        )

    fixtures = []
    if test_fixtures:
        kmp_jvm_library(
            name = name + "_testfixtures_jvm",
            testonly = True,
            srcs = {f: "main" for f in native.glob(["src/testFixtures/kotlin/**/*.kt"], allow_empty = True)},
            fragments = ["main"],
            deps = [":" + lib] + _mvn(test_fixtures_deps),
            # java-test-fixtures gives consumers of the fixtures the main classes too.
            exports = [":" + lib],
            friends = [":" + lib],
            maven_compile_versions = maven_compile_versions,
            resources = _resources(["src/testFixtures/resources"], conventions),
            plugins = plugins,
            kotlinc_opts = opts,
            module_name = module_name + "_testFixtures",
            visibility = visibility,
            tags = tags,
            **platform
        )
        fixtures = [":" + name + "_testfixtures_jvm"]

    native.filegroup(
        name = name + "_sources",
        srcs = native.glob(["src/**", "build.gradle.kts"] + [d + "/**" for d in src_dirs], allow_empty = True),
        visibility = ["//visibility:public"],
    )

    if main_class:
        java_binary(
            name = name + "_bin",
            main_class = main_class,
            runtime_deps = [":" + lib],
            jvm_flags = jvm_flags,
            # Without build-data.properties, whose build time --stamp would change on every build.
            stamp = 0,
            visibility = visibility,
            tags = tags,
        )

    test_srcs = _srcs(test_src_dirs, excludes)
    if test_srcs:
        framework_deps = [
            maven_label(conventions, maven_platform, "org_jetbrains_kotlin_kotlin_test"),
            maven_label(conventions, maven_platform, "org_jetbrains_kotlin_kotlin_test_%s" % ("junit5" if test.framework == "junit5" else "junit")),
        ]
        kmp_jvm_library(
            name = name + "_test_lib",
            testonly = True,
            classpath_first = classpath_first.get("test", []),
            maven_compile_versions = maven_compile_versions,
            srcs = test_srcs,
            fragments = ["main"],
            deps = _dedupe([":" + lib] + fixtures + _mvn(deps + test_deps) + framework_deps),
            compile_only_deps = _mvn(test_compile_only),
            runtime_deps = _mvn(runtime_only + test_runtime_only),
            friends = [":" + lib],
            resources = _resources(test_resource_dirs, conventions),
            plugins = plugins,
            kotlinc_opts = opts,
            module_name = module_name + "_test",
            tags = tags + test.tags,
            **platform
        )
        kmp_jvm_tests(
            name = name + "_test",
            suites = test.suites,
            test_jars = [":" + name + "_test_lib"],
            deps = [":" + name + "_test_lib", require(conventions, "jvm_test_runner", "a JVM test")] + test.runtime_deps.get("jvm", []),
            data = file_labels(conventions, native.glob(["src/*/resources/**"], allow_empty = True)) + test.data,
            tools = test.tools,
            resource_dirs = ["%s/%s" % (native.package_name(), d) for d in test_resource_dirs + resource_dirs],
            own_libs = [":" + lib],
            jvm_flags = test.jvm_flags,
            env = test.env,
            max_heap = test.max_heap,
            workdir = test.workdir,
            size = test.size,
            shard_count = test.shard_count,
            tags = tags + test.tags + (["external"] if test.requires_network else []),
            flaky = test.flaky,
            **(platform | ({"main_class": test.main_class} if test.main_class else {}))
        )
        if on_compilation:
            on_compilation(struct(
                platform = "jvm",
                test = True,
                srcs = list(test_srcs.keys()),
                srcjars = [],
                compilation = ":" + name + "_test_lib",
                kotlinc_opts = opts,
            ))
