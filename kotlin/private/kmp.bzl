"""kmp_library: one Kotlin Multiplatform module, expanded into a target per Kotlin platform.

For `kmp_library(name = "utils", targets = ["jvm", "ios_arm64"])` this creates
`utils_jvm` (JavaInfo), `utils_ios_arm64` (KlibInfo), their test targets `utils_jvm_test` /
`utils_ios_arm64_test`, and the alias `utils` for the JVM (or first) platform.

Source sets follow the Gradle layout (src/<sourceSet>/kotlin) and Kotlin's default hierarchy
template, plus the groups of kmp_conventions(source_set_groups). Each source set is compiled as its
own multiplatform fragment, so expect/actual resolve as in Gradle.

Dependencies are declared once per source set with platform-neutral labels and mapped per
platform: `//lib/utils` becomes `//lib/utils:utils_<platform>`, and `@maven//:foo` becomes
`@maven//<platform>:foo` (for the hub repository of kmp_conventions(maven)).
"""

load("@rules_android//android:rules.bzl", "android_library")
load("//android:aar.bzl", "kmp_android_aar")
load("//android:android.bzl", "EMPTY_MANIFEST", "GENERATED_PACKAGE")
load("//maven:publication.bzl", "PUBLISHED_PLATFORMS", "kmp_publication", "platform_artifact")
load(":compile.bzl", "kmp_jvm_library", "kmp_jvm_rewrap", "kmp_klib")
load(":conventions.bzl", "file_labels", "require")
load(":ksp.bzl", "kmp_ksp")
load(":native.bzl", "MACOS_ONLY", "kmp_native_test")
load(":testing.bzl", "kmp_jvm_tests")
load(":web.bzl", "kmp_web_test")

_PREFIX = {
    "jvm": "jvm",
    "android": "android",
    "ios_arm64": "iosArm64",
    "ios_simulator_arm64": "iosSimulatorArm64",
    "ios_x64": "iosX64",
    "macos_arm64": "macosArm64",
    "macos_x64": "macosX64",
    "js": "js",
    "wasm_js": "wasmJs",
}

NATIVE_PLATFORMS = ["ios_arm64", "ios_simulator_arm64", "ios_x64", "macos_arm64", "macos_x64"]
WEB_PLATFORMS = ["js", "wasm_js"]

# Platforms whose tests run on this host without a device or simulator.
_HOST_NATIVE = ["macos_arm64"]

def _hierarchy(suffix, groups):
    """dependsOn edges of the default hierarchy plus `groups` for Main or Test."""
    s = suffix
    android_test = "androidHostTest" if s == "Test" else "androidMain"
    edges = {
        "common" + s: [],
        "web" + s: ["common" + s],
        "native" + s: ["common" + s],
        "apple" + s: ["native" + s],
        "ios" + s: ["apple" + s],
        "macos" + s: ["apple" + s],
        "jvm" + s: ["common" + s],
        android_test: ["common" + s],
        "js" + s: ["web" + s],
        "wasmJs" + s: ["web" + s],
        "iosArm64" + s: ["ios" + s],
        "iosSimulatorArm64" + s: ["ios" + s],
        "iosX64" + s: ["ios" + s],
        "macosArm64" + s: ["macos" + s],
        "macosX64" + s: ["macos" + s],
    }
    for group, platforms in groups.items():
        edges[group + s] = ["common" + s]
        for platform in platforms:
            leaf = _leaf(platform, s == "Test")
            parents = edges[leaf]
            if "common" + s in parents:
                # The group sits between common and the platform rather than beside common.
                edges[leaf] = [group + s if p == "common" + s else p for p in parents]
            else:
                edges[leaf] = parents + [group + s]
    return edges

def _leaf(platform, test):
    if platform == "android":
        return "androidHostTest" if test else "androidMain"
    return _PREFIX[platform] + ("Test" if test else "Main")

def _closure(leaf, edges):
    """Source sets visible from `leaf`, parents before children."""
    order = []
    visiting = {}

    # Iterative DFS (Starlark has no recursion).
    stack = [(leaf, False)]
    for _ in range(1000):
        if not stack:
            break
        node, expanded = stack.pop()
        if expanded:
            if node not in order:
                order.append(node)
            continue
        if node in visiting:
            continue
        visiting[node] = True
        stack.append((node, True))
        for p in reversed(edges.get(node, [])):
            if p not in visiting:
                stack.append((p, False))
    return order

def _reduce_edges(fragments, edges):
    """Edges between the kept fragments, skipping over dropped (empty) source sets."""
    keep = {f: True for f in fragments}
    result = []
    for f in fragments:
        parents = []
        frontier = list(edges.get(f, []))
        seen = {}
        for _ in range(100):
            if not frontier:
                break
            nxt = []
            for p in frontier:
                if p in seen:
                    continue
                seen[p] = True
                if p in keep:
                    if p not in parents:
                        parents.append(p)
                else:
                    nxt.extend(edges.get(p, []))
            frontier = nxt
        for p in parents:
            result.append("%s:%s" % (f, p))
    return result

def kmp_source_sets(platform, test, conventions):
    """The source sets a compilation of `platform` sees, parents before children.

    Args:
      platform: Kotlin platform, e.g. jvm or ios_arm64.
      test: Whether the test compilation is meant.
      conventions: kmp_conventions() of the repository.

    Returns:
      Source set names, without those of a module's extra_source_sets.
    """
    return _closure(_leaf(platform, test), _hierarchy("Test" if test else "Main", conventions.source_set_groups))

def maven_label(conventions, platform, name):
    """The target of a Maven module in the hub repository of `conventions`."""
    return "%s//%s:%s" % (conventions.maven, platform, name)

def platform_label(label, platform, maven):
    """Maps a platform-neutral dependency label to its per-platform target.

    Args:
      label: `<maven>//:foo` (mapped into the platform's package of the hub), another external
        label or one prefixed with "raw:" (both kept), or a first-party module label (mapped to
        its `<name>_<platform>` target).
      platform: Kotlin platform.
      maven: The hub repository, e.g. "@maven".

    Returns:
      The label of the platform's target.
    """
    if label.startswith(maven + "//:"):
        return "%s//%s:%s" % (maven, platform, label[len(maven + "//:"):])
    if label.startswith(maven + "//") or label.startswith("raw:"):
        return label.removeprefix("raw:")
    if label.startswith("@"):
        return label
    if ":" in label:
        pkg, name = label.rsplit(":", 1)
    else:
        pkg, name = label, label.rsplit("/", 1)[-1]
    return "%s:%s_%s" % (pkg, name, platform)

def _map(labels, platform, conventions):
    out = []
    for l in labels:
        m = platform_label(l, platform, conventions.maven)
        if m not in out:
            out.append(m)
    return out

def _with(labels, extra):
    return labels + [e for e in extra if e not in labels]

def _collect(by_source_set, source_sets):
    out = []
    for ss in source_sets:
        for l in by_source_set.get(ss, []):
            if l not in out:
                out.append(l)
    return out

def _srcs_for(source_sets, extra_srcs, excludes):
    """Globbed sources for each source set: {file label -> fragment}."""
    srcs = {}
    fragments = []
    for ss in source_sets:
        files = native.glob(["src/%s/kotlin/**/*.kt" % ss], exclude = excludes, allow_empty = True)
        files = files + extra_srcs.get(ss, [])
        if files:
            fragments.append(ss)
        for f in files:
            srcs[f] = ss
    return srcs, fragments

def _resources_for(source_sets, extra_resources, conventions):
    res = {}
    for ss in source_sets:
        prefix = "src/%s/resources/" % ss
        for f in file_labels(conventions, native.glob([prefix + "**"], allow_empty = True)):
            res[f] = native.package_name() + "/" + prefix
        for f, strip in extra_resources.get(ss, {}).items():
            res[f] = strip
    return res

def kmp_library(
        name,
        module_name,
        targets,
        conventions,
        deps = {},
        exports = {},
        compile_only = {},
        runtime_only = {},
        plugins = [],
        kotlinc_opts = [],
        opt_ins = [],
        extra_source_sets = {},
        extra_srcs = {},
        extra_resources = {},
        srcjars = {},
        platform_srcs = {},
        ksp_common_processors = [],
        ksp_metadata_processors = [],
        ksp_processors = {},
        ksp_options = {},
        ksp_test_processors = {},
        classpath_first = {},
        maven_compile_versions = False,
        excludes = [],
        short_module_name = None,
        android = None,
        android_wrapper = False,
        kotlin_native = None,
        test = None,
        compose_resources = None,
        maven_artifact = None,
        publication = None,
        on_compilation = None,
        visibility = None,
        tags = []):
    """Declares a Kotlin Multiplatform module.

    Args:
      name: Target name prefix, usually the directory name.
      module_name: Kotlin module name (Gradle's <group>:<project name>).
      targets: Kotlin platforms: jvm, android, ios_arm64, ios_simulator_arm64, ios_x64,
        macos_arm64, macos_x64, js, wasm_js.
      conventions: kmp_conventions() of the repository.
      deps: Source set name -> dependency labels (Gradle api + implementation).
      exports: Source set name -> labels re-exported to dependents (Gradle api).
      compile_only: Source set name -> compile-only labels.
      runtime_only: Source set name -> runtime-only labels.
      plugins: Kotlin compiler plugins.
      kotlinc_opts: Extra compiler flags.
      opt_ins: Opt-in annotations for every source set.
      extra_source_sets: Custom source sets: name -> list of parents; children list them via
        extra_parents in the same dict, e.g. {"jvmSharedMain": ["commonMain"],
        "jvmMain": ["concurrentMain", "jvmSharedMain"]}.
      extra_srcs: Source set name -> additional source files (shared dirs, generated files).
      extra_resources: Source set name -> {file: strip prefix}.
      srcjars: Source set name -> generated source archives.
      platform_srcs: Source set name -> label (or list of labels) of generated sources, where
        "{platform}" is replaced per platform (e.g. ":buildkonfig_{platform}"). The keys
        "platformMain"/"platformTest" stand for each platform's own source set (jvmMain, ...).
      ksp_common_processors: KSP processors run over commonMain as JVM code (for what Gradle's
        kspCommonMainMetadata generates); their output is compiled into commonMain on every platform.
      ksp_metadata_processors: KSP processors run over commonMain for the common platform, as
        Gradle's kspCommonMainMetadata does: processors see the JVM, JS and Native platforms. Only
        what they generate besides code is kept, in the `resources` output group of
        `<name>_ksp_metadata` (e.g. flutter-kmp's Dart files); generated code fails the build. The
        dependencies are read as klibs of the first Kotlin/Native target, so it builds where that
        target does.
      ksp_processors: Platform -> KSP processors run over that platform's main sources (Gradle's
        ksp<Target>); their output is compiled into the platform's own source set.
        `<name>_<platform>_ksp` is the run.
      ksp_options: KSP processor options.
      ksp_test_processors: Platform -> KSP processors run over that platform's test sources.
      classpath_first: {"main"|"test": {platform: [labels]}} put first on the compile classpath.
      maven_compile_versions: The JVM and Android compilations compile against the versions of
        maven.compile_version, as a Gradle build of the module does (see kmp_jvm_library).
      excludes: Glob excludes for sources.
      short_module_name: Kotlin/Native short module name (ObjC/Swift prefix).
      android: Android settings, see android_options(). With kmp_conventions(android_min_sdk,
        android_compile_sdk), `<name>_android_aar` is the Android target as an AAR (see
        kmp_android_aar).
      android_wrapper: For a module with a jvm target but no android one: declare
        `<name>_android`, its JVM jar for Android consumers. Only for modules Android code depends
        on: the wrapper's deps resolve in the hub's android package.
      kotlin_native: Kotlin/Native settings, see native_options().
      test: Test settings, see test_options(); None means tests use the defaults.
      compose_resources: ComposeResourcesInfo target of this module.
      maven_artifact: group:artifact the module is published as, if not module_name; POMs of
        artifacts that depend on it list it so (see maven_pom).
      publication: publication_options() to declare `<name>_publication`, the module's Maven
        publication (see kmp_publication).
      on_compilation: Called with a struct(platform, test, srcs, srcjars, compilation,
        kotlinc_opts) for each compilation the module declares, e.g. to add lint targets that
        analyse its sources: `compilation` is the Kotlin target that compiles them.
      visibility: Visibility of the generated targets.
      tags: Tags for the generated targets.
    """
    if visibility == None:
        visibility = ["//visibility:public"]
    test = test or test_options()
    kotlin_native = kotlin_native or native_options()
    groups = conventions.source_set_groups
    opts = ["-opt-in=" + o for o in opt_ins] + kotlinc_opts
    coordinates = maven_artifact or module_name
    leaves = [_leaf(p, False) for p in targets]
    published = struct(srcs = {}, api = {}, implementation = {}, runtime_only = {}, root_deps = {})
    if ksp_common_processors:
        kmp_ksp(
            name = name + "_ksp_common",
            srcs = native.glob(["src/commonMain/kotlin/**/*.kt"], allow_empty = True) + extra_srcs.get("commonMain", []),
            deps = _with(_map(_collect(deps, ["commonMain"]), "jvm", conventions), [maven_label(conventions, "jvm", "org_jetbrains_kotlin_kotlin_stdlib")]),
            processors = ksp_common_processors,
            options = ksp_options,
            maven_compile_versions = maven_compile_versions,
            module_name = module_name,
            tags = tags,
        )
        srcjars = dict(srcjars)
        srcjars["commonMain"] = srcjars.get("commonMain", []) + [":" + name + "_ksp_common"]

    if ksp_metadata_processors:
        native_targets = [p for p in NATIVE_PLATFORMS if p in targets]
        if not native_targets:
            fail("ksp_metadata_processors reads dependencies as klibs, so it needs a Kotlin/Native target")
        common_platform_srcs = platform_srcs.get("commonMain", [])
        kmp_ksp(
            name = name + "_ksp_metadata",
            mode = "common",
            target = native_targets[0],
            srcs = native.glob(["src/commonMain/kotlin/**/*.kt"], exclude = excludes, allow_empty = True) +
                   extra_srcs.get("commonMain", []) +
                   [t.format(platform = native_targets[0]) for t in ([common_platform_srcs] if type(common_platform_srcs) == "string" else common_platform_srcs)],
            srcjars = srcjars.get("commonMain", []),
            deps = _map(_collect(deps, ["commonMain"]) + _collect(compile_only, ["commonMain"]), native_targets[0], conventions),
            processors = ksp_metadata_processors,
            options = ksp_options,
            no_sources = True,
            module_name = module_name,
            target_compatible_with = MACOS_ONLY,
            visibility = visibility,
            tags = tags,
        )

    for test_mode in [False, True]:
        suffix = "Test" if test_mode else "Main"
        edges = _hierarchy(suffix, groups)
        for ss, parents in extra_source_sets.items():
            if ss.endswith(suffix):
                edges[ss] = parents
        for platform in targets:
            visible = _closure(_leaf(platform, test_mode), edges)
            srcs, fragments = _srcs_for(visible, extra_srcs, excludes)
            if publication and not test_mode:
                for f, ss in srcs.items():
                    if ss not in leaves:
                        _add_platform(published.srcs, f, "root=" + ss)
                for ss in visible:
                    if ss not in leaves:
                        for l in deps.get(ss, []):
                            _add_platform(published.root_deps, platform_label(l, platform, conventions.maven), "root")
            leaf = _leaf(platform, test_mode)
            for key, templates in platform_srcs.items():
                ss = leaf if key == ("platformTest" if test_mode else "platformMain") else key
                if ss not in visible:
                    continue
                for t in ([templates] if type(templates) == "string" else templates):
                    srcs[t.format(platform = platform)] = ss
                if ss not in fragments:
                    fragments.append(ss)
            gen = {}
            for ss in visible:
                for j in srcjars.get(ss, []):
                    gen[j] = ss
                    if ss not in fragments:
                        fragments.append(ss)
            fragments = [f for f in visible if f in fragments]
            refines = _reduce_edges(fragments, edges)
            lib_deps = _map(_collect(deps, visible), platform, conventions)
            lib_exports = _map(_collect(exports, visible), platform, conventions)
            # Test compilations also see their main compilation's compileOnly dependencies (Gradle's
            # associated compilations).
            compile_only_sets = visible + (_closure(_leaf(platform, False), _hierarchy("Main", groups)) if test_mode else [])
            lib_compile_only = _map(_collect(compile_only, compile_only_sets), platform, conventions)
            lib_runtime = _map(_collect(runtime_only, visible), platform, conventions)
            main_label = ":%s_%s" % (name, platform)
            base = "%s_%s" % (name, platform)
            if not test_mode and ksp_processors.get(platform):
                native_platform = platform in NATIVE_PLATFORMS
                kmp_ksp(
                    name = base + "_ksp",
                    mode = "native" if native_platform else "jvm",
                    target = platform if native_platform else "",
                    srcs = list(srcs.keys()),
                    srcjars = list(gen.keys()),
                    deps = _with(
                        _with(_with(lib_deps, lib_exports), lib_compile_only),
                        [] if native_platform else [maven_label(conventions, platform, "org_jetbrains_kotlin_kotlin_stdlib")],
                    ),
                    android_jar = require(conventions, "android_jar", "an android target") if platform == "android" else None,
                    processors = ksp_processors[platform],
                    options = ksp_options,
                    maven_compile_versions = maven_compile_versions,
                    module_name = module_name,
                    target_compatible_with = MACOS_ONLY if native_platform else [],
                    visibility = visibility,
                    tags = tags,
                )
                gen = dict(gen)
                gen[":" + base + "_ksp"] = leaf
                if leaf not in fragments:
                    fragments = fragments + [leaf]
                    refines = _reduce_edges(fragments, edges)
            if test_mode:
                if not srcs and not gen:
                    continue
                declared = _declare_test(
                    name = base + "_test",
                    platform = platform,
                    main_label = main_label,
                    srcs = srcs,
                    srcjars = gen,
                    fragments = fragments,
                    refines = refines,
                    deps = _with(lib_deps, lib_exports),
                    compile_only = lib_compile_only,
                    runtime_deps = lib_runtime,
                    plugins = plugins,
                    kotlinc_opts = opts,
                    module_name = module_name + "_test",
                    resources = _resources_for(visible, extra_resources, conventions),
                    test = test,
                    ksp_processors = ksp_test_processors.get(platform, []),
                    classpath_first = classpath_first.get("test", {}).get(platform, []),
                    maven_compile_versions = maven_compile_versions,
                    ksp_options = ksp_options,
                    kotlin_native = kotlin_native,
                    android = android,
                    conventions = conventions,
                    tags = tags,
                )
                if declared and on_compilation:
                    on_compilation(struct(
                        platform = platform,
                        test = True,
                        srcs = list(srcs.keys()),
                        srcjars = list(gen.keys()) + ([":%s_test_ksp" % base] if ksp_test_processors.get(platform) else []),
                        compilation = main_label + "_test_lib",
                        kotlinc_opts = opts,
                    ))
                continue
            if publication:
                _collect_published(published, platform, visible, leaves, srcs, gen, lib_exports, lib_deps, lib_runtime, excludes)
            common = dict(
                srcs = srcs,
                srcjars = gen,
                fragments = fragments,
                refines = refines,
                plugins = plugins,
                kotlinc_opts = opts,
                module_name = module_name,
                maven_artifact = maven_artifact or "",
                maven_platform_artifact = platform_artifact(coordinates, platform),
                tags = tags,
            )
            if platform in ("jvm", "android"):
                _declare_jvm_like(
                    name = base,
                    platform = platform,
                    classpath_first = classpath_first.get("main", {}).get(platform, []),
                    maven_compile_versions = maven_compile_versions,
                    deps = lib_deps,
                    exports = lib_exports,
                    compile_only = lib_compile_only,
                    runtime_deps = lib_runtime,
                    resources = _resources_for(visible, extra_resources, conventions),
                    compose_resources = compose_resources,
                    android = android,
                    conventions = conventions,
                    visibility = visibility,
                    **common
                )
            else:
                kmp_klib(
                    name = base,
                    target_compatible_with = MACOS_ONLY if platform in NATIVE_PLATFORMS else [],
                    target = platform,
                    deps = lib_deps,
                    exports = lib_exports,
                    runtime_deps = lib_runtime,
                    short_module_name = short_module_name or "",
                    cinterop_klibs = kotlin_native.cinterops.get(platform, []),
                    linkopts = kotlin_native.linkopts,
                    link_inputs = kotlin_native.link_inputs.get(platform, []),
                    compose_resources = compose_resources,
                    visibility = visibility,
                    **common
                )
            if on_compilation:
                on_compilation(struct(
                    platform = platform,
                    test = False,
                    srcs = list(srcs.keys()),
                    srcjars = list(gen.keys()),
                    compilation = main_label + ("_kt" if platform == "android" else ""),
                    kotlinc_opts = opts,
                ))

    if "android" in targets and android and android.device_tests:
        device_test = require(conventions, "android_device_test", "an Android device test")
        assets_dir = android.device_test_assets_dir
        assets = file_labels(conventions, native.glob([assets_dir + "/**"], allow_empty = True)) if assets_dir else []
        sdk_versions = {k: str(v) for k, v in [("min_sdk", android.device_test_min_sdk), ("target_sdk", android.device_test_target_sdk)] if v}
        manifest = native.glob(["src/androidDeviceTest/AndroidManifest.xml"], allow_empty = True)
        device_srcs, device_fragments = _srcs_for(["androidDeviceTest"], extra_srcs, excludes)
        device_test(
            name = name + "_android_device_test",
            main_label = ":%s_android" % name,
            namespace = android.namespace,
            lib_kwargs = dict(
                srcs = device_srcs,
                fragments = device_fragments,
                compile_only_deps = _map(_collect(compile_only, _closure(_leaf("android", False), _hierarchy("Main", groups))), "android", conventions),
                maven_compile_versions = maven_compile_versions,
                plugins = plugins,
                kotlinc_opts = opts,
                module_name = module_name + "_deviceTest",
                resources = _resources_for(["androidDeviceTest"], extra_resources, conventions),
            ),
            deps = _with(_map(_collect(deps, ["androidDeviceTest"]), "android", conventions), [maven_label(conventions, "android", "org_jetbrains_kotlin_kotlin_test_junit")]),
            runtime_deps = _map(_collect(runtime_only, ["androidDeviceTest"]), "android", conventions),
            manifest = manifest[0] if manifest else None,
            assets = assets,
            assets_dir = assets_dir,
            runner_args = android.device_test_runner_args,
            tags = tags,
            **sdk_versions
        )

    native.filegroup(
        name = name + "_sources",
        srcs = native.glob(["src/**", "build.gradle.kts"], allow_empty = True),
        visibility = ["//visibility:public"],
    )

    if publication:
        if "android" in targets and not (conventions.android_min_sdk and conventions.android_compile_sdk):
            fail("publishing an Android target needs kmp_conventions(android_min_sdk, android_compile_sdk)")
        platforms = sorted(targets, key = lambda p: PUBLISHED_PLATFORMS[p][0])
        kmp_publication(
            name = name + "_publication",
            coordinates = coordinates,
            kind = "kmp",
            platforms = platforms,
            artifacts = {":%s_%s" % (name, p) + ("_aar" if p == "android" else ""): p for p in targets},
            cinterops = {c: p for p in targets for c in kotlin_native.cinterops.get(p, [])},
            srcs = {f: " ".join(v) for f, v in published.srcs.items()},
            api = {l: " ".join(v) for l, v in published.api.items()},
            implementation = {l: " ".join(v) for l, v in published.implementation.items()},
            runtime_only = {l: " ".join(v) for l, v in published.runtime_only.items()},
            root_deps = {l: " ".join(v) for l, v in published.root_deps.items()},
            compose_resources = compose_resources,
            resources_package = publication.resources_package,
            jars = publication.jars,
            pom_name = publication.name,
            pom_description = publication.description,
            target_compatible_with = MACOS_ONLY if [p for p in targets if p in NATIVE_PLATFORMS] else [],
            visibility = visibility,
            tags = tags + ["manual"],
        )

    # A module without an Android target is consumed through its JVM jar, as in Gradle.
    if android_wrapper and "android" not in targets and "jvm" in targets:
        jvm_visible = _closure(_leaf("jvm", False), _hierarchy("Main", groups))
        android_deps = _with(_map(_collect(deps, jvm_visible), "android", conventions), [maven_label(conventions, "android", "org_jetbrains_kotlin_kotlin_stdlib")])
        android_runtime = _map(_collect(runtime_only, jvm_visible), "android", conventions)
        kmp_jvm_rewrap(
            name = name + "_android_jar",
            lib = ":%s_jvm" % name,
            deps = android_deps,
            exports = _map(_collect(exports, jvm_visible), "android", conventions),
            runtime_deps = android_runtime,
            visibility = visibility,
            tags = tags + ["manual"],
        )
        android_library(
            name = name + "_android",
            exports = _with([":%s_android_jar" % name], _with(android_deps, android_runtime)),
            manifest = EMPTY_MANIFEST,
            custom_package = GENERATED_PACKAGE,
            visibility = visibility,
            tags = tags + ["manual"],
        )
    native.alias(
        name = name,
        actual = ":%s_%s" % (name, "jvm" if "jvm" in targets else targets[0]),
        visibility = visibility,
    )

def _collect_published(published, platform, visible, leaves, srcs, gen, api, implementation, runtime_only, excludes):
    """Adds a main compilation's sources and dependencies to what the module publishes."""
    for f, ss in srcs.items():
        _add_platform(published.srcs, f, "%s=%s" % (platform, ss))
    for ss in visible:
        # Gradle's sources jars take everything in the source directories.
        for f in native.glob(["src/%s/kotlin/**" % ss], exclude = ["**/*.kt"] + excludes, allow_empty = True):
            _add_platform(published.srcs, f, "%s=%s" % (platform, ss))
            if ss not in leaves:
                _add_platform(published.srcs, f, "root=" + ss)
    for j, ss in gen.items():
        _add_platform(published.srcs, j, "%s=%s" % (platform, ss))
    for kind, labels in [("api", api), ("implementation", implementation), ("runtime_only", runtime_only)]:
        for l in labels:
            _add_platform(getattr(published, kind), l, platform)

def _add_platform(d, key, value):
    values = d.setdefault(key, [])
    if value not in values:
        values.append(value)

def _declare_jvm_like(name, platform, deps, exports, compile_only, runtime_deps, resources, compose_resources, android, conventions, visibility, maven_compile_versions, classpath_first = [], **common):
    if platform == "jvm":
        kmp_jvm_library(
            name = name,
            classpath_first = classpath_first,
            maven_compile_versions = maven_compile_versions,
            deps = deps,
            exports = exports,
            compile_only_deps = compile_only,
            runtime_deps = runtime_deps,
            resources = resources,
            compose_resources = compose_resources,
            visibility = visibility,
            **common
        )
        return
    android = android or android_options()
    res_deps = []
    if android.resource_files or android.enable_resources or android.assets or android.manifest:
        # Depends on all dependencies: a library's resources and manifest take priority over its
        # dependencies' (e.g. tools:node="remove" for an activity a dependency declares).
        android_library(
            name = name + "_res",
            manifest = android.manifest or EMPTY_MANIFEST,
            exports_manifest = bool(android.manifest),
            custom_package = android.namespace,
            resource_files = file_labels(conventions, android.resource_files),
            assets = file_labels(conventions, android.assets),
            assets_dir = android.assets_dir,
            deps = _with(deps, exports),
            visibility = visibility,
            tags = common["tags"],
        )
        res_deps = [":" + name + "_res"]
    kmp_jvm_library(
        name = name + "_kt",
        deps = deps + res_deps,
        exports = exports,
        compile_only_deps = compile_only,
        runtime_deps = runtime_deps,
        resources = resources,
        compose_resources = compose_resources,
        maven_compile_versions = maven_compile_versions,
        android_jar = require(conventions, "android_jar", "an android target"),
        visibility = visibility,
        **common
    )
    # Every dependency is a dep of this android_library: android_binary only collects resources,
    # manifests and native libraries through Android rules, and AGP merges those of all transitive
    # dependencies. The module's own resources come first so its manifest outranks theirs (e.g.
    # tools:node="remove"). Only the module's code, R class and exports (Gradle's api) are
    # exported, so a consumer compiles against what it would see in Gradle.
    android_library(
        name = name,
        exports = [":" + name + "_kt"] + res_deps,
        deps = _with(_with(_with(res_deps, exports), deps), runtime_deps),
        manifest = EMPTY_MANIFEST,
        custom_package = android.namespace,
        proguard_specs = android.consumer_proguard_specs,
        visibility = visibility,
        tags = common["tags"],
    )
    if conventions.android_min_sdk and conventions.android_compile_sdk:
        kmp_android_aar(
            name = name + "_aar",
            classes = ":" + name + "_kt",
            resources = res_deps[0] if res_deps else None,
            namespace = android.namespace,
            min_sdk = conventions.android_min_sdk,
            min_compile_sdk = conventions.android_compile_sdk,
            android_jar = require(conventions, "android_jar", "an android target"),
            proguard_specs = android.consumer_proguard_specs,
            deps = _with(_with(deps, exports), runtime_deps),
            visibility = visibility,
            tags = common["tags"] + ["manual"],
        )

def _declare_test(name, platform, main_label, srcs, srcjars, fragments, refines, deps, compile_only, runtime_deps, plugins, kotlinc_opts, module_name, resources, test, ksp_processors, ksp_options, kotlin_native, android, conventions, tags, maven_compile_versions, classpath_first = []):
    """Declares the test of one platform; returns whether there is one."""
    test_tags = tags + test.tags + test.platform_tags.get(platform, [])
    android = android or android_options()
    if platform == "android" and not android.host_tests:
        return False
    groups = conventions.source_set_groups
    pkg = native.package_name()
    main_sets = _closure(_leaf(platform, False), _hierarchy("Main", groups))
    test_sets = _closure(_leaf(platform, True), _hierarchy("Test", groups))
    resource_dirs = ["%s/src/%s/resources" % (pkg, ss) for ss in reversed(test_sets) + list(reversed(main_sets))]
    if ksp_processors:
        leaf = _leaf(platform, True)
        kmp_ksp(
            name = name + "_ksp",
            testonly = True,
            srcs = [f for f, ss in srcs.items() if ss == leaf],
            common_srcs = [f for f, ss in srcs.items() if ss != leaf],
            deps = deps,
            friends = [main_label],
            processors = ksp_processors,
            options = ksp_options,
            maven_compile_versions = maven_compile_versions,
            module_name = module_name,
            tags = test_tags,
        )
        srcjars = dict(srcjars)
        srcjars[":" + name + "_ksp"] = leaf
        if leaf not in fragments:
            fragments = fragments + [leaf]
    if platform == "android":
        host_test = require(conventions, "android_host_test", "an Android host test")
        host_test(
            name = name,
            main_label = main_label,
            lib_kwargs = dict(
                srcs = srcs,
                srcjars = srcjars,
                fragments = fragments,
                refines = refines,
                compile_only_deps = compile_only,
                maven_compile_versions = maven_compile_versions,
                plugins = plugins,
                kotlinc_opts = kotlinc_opts,
                module_name = module_name,
                resources = resources,
            ),
            deps = deps,
            runtime_deps = runtime_deps,
            test = test,
            android = android,
            resource_dirs = resource_dirs,
            data = file_labels(conventions, native.glob(["src/*/resources/**"], allow_empty = True)) + test.data,
            tags = test_tags,
        )
        return True
    if platform == "jvm":
        framework_deps = [
            maven_label(conventions, platform, "org_jetbrains_kotlin_kotlin_test"),
            maven_label(conventions, platform, "org_jetbrains_kotlin_kotlin_test_%s" % ("junit5" if test.framework == "junit5" else "junit")),
        ]
        kmp_jvm_library(
            name = name + "_lib",
            testonly = True,
            classpath_first = classpath_first,
            maven_compile_versions = maven_compile_versions,
            srcs = srcs,
            srcjars = srcjars,
            fragments = fragments,
            refines = refines,
            deps = _with(_with([main_label], deps), framework_deps),
            compile_only_deps = compile_only,
            runtime_deps = runtime_deps,
            friends = [main_label],
            plugins = plugins,
            kotlinc_opts = kotlinc_opts,
            module_name = module_name,
            resources = resources,
            tags = test_tags,
        )
        kmp_jvm_tests(
            name = name,
            suites = test.suites,
            test_jars = [":" + name + "_lib"],
            deps = [":" + name + "_lib", require(conventions, "jvm_test_runner", "a JVM test")] + test.runtime_deps.get(platform, []),
            data = file_labels(conventions, native.glob(["src/*/resources/**"], allow_empty = True)) + test.data,
            tools = test.tools,
            resource_dirs = resource_dirs,
            own_libs = [main_label],
            jvm_flags = test.jvm_flags,
            env = test.env,
            max_heap = test.max_heap,
            workdir = test.workdir,
            size = test.size,
            shard_count = test.shard_count,
            tags = test_tags + (["external"] if test.requires_network else []),
            flaky = test.flaky,
            **({"main_class": test.main_class} if test.main_class else {})
        )
        return True
    kmp_klib(
        name = name + "_lib",
        testonly = True,
        target_compatible_with = MACOS_ONLY if platform in NATIVE_PLATFORMS else [],
        target = platform,
        srcs = srcs,
        srcjars = srcjars,
        fragments = fragments,
        refines = refines,
        deps = _with(_with([main_label], deps), [] if platform in NATIVE_PLATFORMS else [maven_label(conventions, platform, "org_jetbrains_kotlin_kotlin_test_%s" % platform)]),
        friends = [main_label],
        plugins = plugins,
        kotlinc_opts = kotlinc_opts,
        module_name = module_name,
        tags = test_tags,
    )
    if platform in NATIVE_PLATFORMS:
        run_tags = []
        if platform not in _HOST_NATIVE:
            if platform == "ios_simulator_arm64" and kotlin_native.simulator_tests:
                run_tags = ["requires-simulator"]
            elif platform in ("ios_simulator_arm64", "ios_x64"):
                run_tags = ["manual", "requires-simulator"]
            else:
                run_tags = ["manual", "requires-device"]
        kmp_native_test(
            name = name,
            target_compatible_with = MACOS_ONLY,
            test_klib = ":" + name + "_lib",
            target = platform,
            data = test.native_data,
            linkopts = kotlin_native.test_linkopts,
            link_inputs = kotlin_native.test_link_inputs.get(platform, []),
            bundle_id_prefix = conventions.native_test_bundle_id_prefix,
            exec_properties = conventions.native_test_exec_properties,
            tags = test_tags + run_tags,
            size = test.size,
        )
    else:
        kmp_web_test(
            name = name,
            test_klib = ":" + name + "_lib",
            target = platform,
            node = require(conventions, "web_test_node", "a JS or Wasm test"),
            npm_packages = conventions.web_test_npm_packages,
            tags = test_tags,
            size = test.size,
        )
    return True

def test_options(
        framework = "junit5",
        data = [],
        tools = [],
        native_data = [],
        jvm_flags = [],
        env = {},
        max_heap = "2g",
        workdir = None,
        size = "medium",
        shard_count = None,
        tags = [],
        runtime_deps = {},
        requires_network = False,
        flaky = False,
        platform_tags = {},
        suites = {},
        main_class = None):
    """Settings for a kmp_library's test targets.

    Args:
      framework: junit5 (JUnit Platform) or junit4: picks kotlin-test-junit5 or kotlin-test-junit.
      data: Runtime files of JVM/Android tests.
      tools: Programs JVM tests start, built for the platform the tests run on (kmp_jvm_test.tools).
      native_data: Runtime files of native tests, placed next to the test binary.
      jvm_flags: Extra JVM flags; $(location) is expanded against data and tools.
      env: Environment variables; $(location) and the placeholders of jvm_flags ({runfiles}) are expanded.
      max_heap: -Xmx of the test JVM.
      workdir: Working directory relative to the workspace root (default: the package).
      size: Bazel test size.
      shard_count: Bazel shard count.
      tags: Extra tags.
      runtime_deps: Platform -> extra runtime dependencies.
      requires_network: The tests talk to real third-party services: tagged "external", so they
        are not cached and only run when selected explicitly (--config=external).
      flaky: Mark as flaky.
      platform_tags: Platform -> extra tags of that platform's test target.
      suites: JVM test classes that run as their own target, see kmp_jvm_tests.
      main_class: Main class of JVM tests, in place of the JUnit Platform runner, e.g. one that
        prepares something before handing over to it.
    """
    return struct(
        framework = framework,
        data = data,
        tools = tools,
        native_data = native_data,
        jvm_flags = jvm_flags,
        env = env,
        max_heap = max_heap,
        workdir = workdir,
        size = size,
        shard_count = shard_count,
        tags = tags,
        runtime_deps = runtime_deps,
        requires_network = requires_network,
        flaky = flaky,
        platform_tags = platform_tags,
        suites = suites,
        main_class = main_class,
    )

def android_options(
        namespace = None,
        manifest = None,
        resource_files = [],
        enable_resources = False,
        assets = [],
        assets_dir = None,
        consumer_proguard_specs = [],
        host_tests = True,
        include_android_resources = False,
        device_tests = False,
        device_test_assets_dir = "src/androidDeviceTest/assets",
        device_test_runner_args = {},
        device_test_min_sdk = None,
        device_test_target_sdk = None):
    """Android settings of a kmp_library's android target.

    Args:
      namespace: The Android namespace (R class package).
      manifest: AndroidManifest.xml of androidMain.
      resource_files: Android resource files.
      enable_resources: Build an R class even without resource files.
      assets: Android assets.
      assets_dir: Directory of the assets, relative to the package.
      consumer_proguard_specs: Keep rules for consumers.
      host_tests: Gradle's withHostTest {}: commonTest and androidHostTest run as an Android host
        test. Without it Gradle runs no Android tests at all.
      include_android_resources: AGP's isIncludeAndroidResources: host tests see the linked
        resources of the module and its dependencies (Robolectric, Paparazzi).
      device_tests: Gradle's withDeviceTest {}: src/androidDeviceTest runs on a device, through
        kmp_conventions(android_device_test).
      device_test_assets_dir: Directory of the device test APK's assets, relative to the package
        (the asset directory AGP's Variant API gives the device test), or None for no assets.
      device_test_runner_args: Gradle's instrumentationRunnerArguments.
      device_test_min_sdk: minSdkVersion of the device test APK; the convention's default if unset.
      device_test_target_sdk: targetSdkVersion of the device test APK; the convention's default if
        unset.
    """
    return struct(
        namespace = namespace,
        manifest = manifest,
        resource_files = resource_files,
        enable_resources = enable_resources,
        assets = assets,
        assets_dir = assets_dir,
        consumer_proguard_specs = consumer_proguard_specs,
        host_tests = host_tests,
        include_android_resources = include_android_resources,
        device_tests = device_tests,
        device_test_assets_dir = device_test_assets_dir,
        device_test_runner_args = device_test_runner_args,
        device_test_min_sdk = device_test_min_sdk,
        device_test_target_sdk = device_test_target_sdk,
    )

def native_options(cinterops = {}, linkopts = [], link_inputs = {}, test_linkopts = [], test_link_inputs = {}, simulator_tests = False):
    """Kotlin/Native settings: cinterop klibs and what linking a binary needs.

    Args:
      cinterops: Platform -> cinterop klibs (kmp_cinterop targets) the module compiles against.
      linkopts: Linker flags for executables that include the module.
      link_inputs: Platform -> files or NativeLinkInfo targets linked into such executables.
      test_linkopts: Linker flags for the module's own test executables.
      test_link_inputs: Platform -> link inputs of the module's own test executables.
      simulator_tests: Run the ios_simulator_arm64 tests with --config=simulator, like the
        ios-simulator-tests Gradle plugin; otherwise they are tagged manual.
    """
    return struct(
        cinterops = cinterops,
        linkopts = linkopts,
        link_inputs = link_inputs,
        test_linkopts = test_linkopts,
        test_link_inputs = test_link_inputs,
        simulator_tests = simulator_tests,
    )
