"""Exposes the pinned third-party artifacts of maven_lock.json as Bazel targets.

One repository per artifact file (downloaded lazily, verified by sha256) plus a hub repository
(@maven unless maven.lock(name) says otherwise) with a package per platform:

    @maven//jvm:org_jetbrains_kotlinx_kotlinx_coroutines_core
    @maven//android:androidx_core_core_ktx
    @maven//ios_arm64:org_jetbrains_kotlinx_kotlinx_coroutines_core

@maven//:<name> aliases the jvm target, for plain JVM code.

The maven.repository, maven.artifact, maven.compile_version and maven.omit_dependency tags declare
what the lock holds; `bazel run @maven//:pin` resolves them with Gradle and rewrites the lock.
"""

load("@bazel_tools//tools/build_defs/repo:http.bzl", "http_archive", "http_file")
load(":libs.bzl", "maven_libs_repository")

# The Gradle distribution `bazel run @maven//:pin` resolves with.
_GRADLE_VERSION = "9.6.1"
_GRADLE_SHA256 = "9c0f7faeeb306cb14e4279a3e084ca6b596894089a0638e68a07c945a32c9e14"

def target_name(coordinate):
    """Bazel target name of a group:module coordinate."""
    out = []
    for c in coordinate.elems():
        out.append(c if (c.isalnum() or c == "_") else "_")
    return "".join(out)

def _repo_name(file_id):
    return "maven__" + target_name(file_id)

# Lock platform -> the kind of targets its artifacts become. "tools" holds what runs at build time
# (compiler plugins, KSP processors).
_PLATFORM_RULES = {
    "jvm": "jvm",
    "tools": "jvm",
    "android": "android",
    "ios_arm64": "klib",
    "ios_simulator_arm64": "klib",
    "ios_x64": "klib",
    "macos_arm64": "klib",
    "macos_x64": "klib",
    "js": "klib",
    "wasm_js": "klib",
}

def _label_list(items):
    return "[" + ", ".join(['"%s"' % i for i in items]) + "]"

def _hub_impl(rctx):
    lock = json.decode(rctx.read(rctx.attr.lock)) if rctx.attr.lock else {"artifacts": {}, "platforms": {}}
    artifacts = lock["artifacts"]
    kinds = dict(_PLATFORM_RULES)
    for platform, like in rctx.attr.platforms.items():
        kinds[platform] = _PLATFORM_RULES[like]
    pods = rctx.attr.link_pods_package
    root_aliases = []
    for platform, modules in lock["platforms"].items():
        if platform not in kinds:
            fail("maven.lock(platforms) does not say what platform %s of the lock is" % platform)
        kind = kinds[platform]
        lines = [
            'load("%s", "maven_aar", "maven_android_library", "maven_jar", "maven_klib")' % Label("//maven:import.bzl"),
            "",
            'package(default_visibility = ["//visibility:public"])',
            "",
        ]
        for coord, entry in sorted(modules.items()):
            name = target_name(coord)
            if "alias" in entry:
                lines.append('alias(name = "%s", actual = "//%s:%s")\n' % (name, entry["alias"], name))
                continue
            files = ["@%s//file" % _repo_name(f) for f in entry["files"]]
            file_names = [artifacts[f]["file"] for f in entry["files"]]
            deps = [":" + target_name(d) for d in entry["deps"]]
            runtime_deps = [":" + target_name(d) for d in entry["runtime_deps"]]
            common = '    coordinates = "%s:%s",\n    deps = %s,\n' % (coord, entry["version"], _label_list(deps))
            if kind == "klib":
                # Linking a binary needs runtime-only dependencies too, so klibs carry both.
                klibs = [f for f, n in zip(files, file_names) if n.endswith(".klib")]
                link_pods = entry.get("link_pods", [])
                if link_pods and not pods:
                    fail("%s links pods; maven.lock(link_pods_package) must say where their targets are" % coord)
                link_inputs = ["@@%s//%s:link_%s_%s" % (pods.repo_name, pods.package, p, platform) for p in link_pods]
                lines.append('maven_klib(\n    name = "%s",\n%s    klibs = %s,\n%s    target = "%s",\n)\n' % (
                    name,
                    '    coordinates = "%s:%s",\n    deps = %s,\n' % (coord, entry["version"], _label_list(deps + [r for r in runtime_deps if r not in deps])),
                    _label_list(klibs),
                    '    link_inputs = %s,\n' % _label_list(link_inputs) if link_inputs else "",
                    platform,
                ))
                continue
            aars = [f for f, n in zip(files, file_names) if n.endswith(".aar")]
            jars = [f for f, n in zip(files, file_names) if n.endswith(".jar")]
            compile_jars = [
                "@%s//file" % _repo_name(f)
                for f in entry.get("compile_files", [])
                if artifacts[f]["file"].endswith(".jar")
            ]
            if kind == "android" and aars:
                lines.append('maven_aar(\n    name = "%s",\n%s    aar = "%s",\n    jars = %s,\n    runtime_deps = %s,\n)\n' % (
                    name,
                    common,
                    aars[0],
                    _label_list(jars),
                    _label_list(runtime_deps),
                ))
            elif kind == "android":
                # android_library, so the resources, manifests and native libraries of AARs further
                # down reach the APK through jar-only or Gradle-metadata-only modules too. Only the
                # compile-scope deps are exported, i.e. reach a consumer's compile classpath.
                exports = deps
                if jars:
                    lines.append('maven_jar(\n    name = "%s_jar",\n%s    jars = %s,\n    compile_jars = %s,\n    runtime_deps = %s,\n)\n' % (
                        name,
                        common,
                        _label_list(jars),
                        _label_list(compile_jars),
                        _label_list(runtime_deps),
                    ))
                    exports = [":%s_jar" % name] + exports
                lines.append('maven_android_library(\n    name = "%s",\n    exports = %s,\n    deps = %s,\n)\n' % (name, _label_list(exports), _label_list(runtime_deps)))
            else:
                lines.append('maven_jar(\n    name = "%s",\n%s    jars = %s,\n    compile_jars = %s,\n    runtime_deps = %s,\n)\n' % (
                    name,
                    common,
                    _label_list(jars),
                    _label_list(compile_jars),
                    _label_list(runtime_deps),
                ))
                if compile_jars:
                    # For modules Gradle compiled against the runtime version (see classpath_first).
                    lines.append('maven_jar(\n    name = "%s__runtime_version",\n%s    jars = %s,\n)\n' % (
                        name,
                        common,
                        _label_list(jars),
                    ))
            if platform == "jvm":
                root_aliases.append(name)
        rctx.file(platform + "/BUILD.bazel", "\n".join(lines))
    rctx.file("pin.json", rctx.attr.pin_config)
    root = [
        'load("%s", "maven_pin")' % Label("//maven/pin:defs.bzl"),
        "",
        'package(default_visibility = ["//visibility:public"])',
        "",
        'maven_pin(name = "pin", config = "pin.json", gradle = "%s")' % rctx.attr.gradle,
        "",
    ]
    for name in root_aliases:
        root.append('alias(name = "%s", actual = "//jvm:%s")' % (name, name))
    rctx.file("BUILD.bazel", "\n".join(root) + "\n")

_LOCK_ATTRS = {
    "platforms": attr.string_dict(doc = "Further lock platforms -> the built-in platform they resolve like, e.g. {\"jvm_server\": \"jvm\"} for a second JVM resolution. Their modules at a version compatible with the built-in platform's alias its targets."),
    "link_pods_package": attr.label(doc = "A label in the package that defines link_<pod>_<platform>, the link inputs of the lock's link_pods."),
}

_hub = repository_rule(
    implementation = _hub_impl,
    attrs = _LOCK_ATTRS | {
        "lock": attr.label(doc = "The lock; None before the first pin."),
        "pin_config": attr.string(mandatory = True, doc = "The declarations the hub's pin target resolves (JSON)."),
        "gradle": attr.label(mandatory = True, doc = "The files of the Gradle distribution that resolves."),
    },
)

def _check_coordinates(coordinates, parts, what):
    n = len(coordinates.split(":"))
    if n not in parts:
        fail("%s(coordinates = %r): expected %s" % (what, coordinates, " or ".join([
            {3: "group:module:version", 4: "group:module:version:classifier"}[p]
            for p in parts
        ])))

def _check_platforms(platforms, known, what):
    for p in platforms:
        if p not in known:
            fail("%s names platform %s, which is neither built in nor in maven.lock(platforms): %s" % (
                what,
                p,
                ", ".join(sorted(known)),
            ))

def _pin_config(module_ctx, lock_tag):
    """The declarations of every module's tags, for the lock generator."""
    known = {p: True for p in list(_PLATFORM_RULES) + list(lock_tag.platforms)}
    repositories, artifacts, compile_versions, omitted = [], [], [], []
    for mod in module_ctx.modules:
        for tag in mod.tags.repository:
            repositories.append({"name": tag.name, "url": tag.url, "groups": tag.groups})
        for tag in mod.tags.artifact:
            what = "maven.artifact(%s)" % tag.coordinates
            _check_coordinates(tag.coordinates, [3, 4], "maven.artifact")
            _check_platforms(tag.platforms, known, what)
            if tag.bom and tag.excludes:
                fail("%s: a bom has no dependencies to exclude" % what)
            artifacts.append({
                "coordinates": tag.coordinates,
                "platforms": tag.platforms,
                "scope": tag.scope,
                "excludes": tag.excludes,
                "bom": tag.bom,
            })
        for tag in mod.tags.compile_version:
            _check_coordinates(tag.coordinates, [3], "maven.compile_version")
            _check_platforms(tag.platforms, known, "maven.compile_version(%s)" % tag.coordinates)
            compile_versions.append({"coordinates": tag.coordinates, "platforms": tag.platforms})
        for tag in mod.tags.omit_dependency:
            omitted.append({"module": tag.module, "dependency": tag.dependency})
    if artifacts and not repositories:
        fail("maven.artifact needs at least one maven.repository to resolve from")
    lock = lock_tag.file
    return {
        "lock": lock.package + "/" + lock.name if lock.package else lock.name,
        "platforms": lock_tag.platforms,
        "jvm_version": lock_tag.jvm_version,
        "repositories": repositories,
        "artifacts": artifacts,
        "compile_versions": compile_versions,
        "omit_dependencies": omitted,
    }

def _maven_impl(module_ctx):
    lock_tag = None
    for mod in module_ctx.modules:
        for tag in mod.tags.lock:
            lock_tag = tag
    if lock_tag == None:
        # rules_kmp itself uses the extension, for the libraries its toolchains take from a hub.
        maven_libs_repository(name = "kmp_maven_libs")
        return module_ctx.extension_metadata(reproducible = True)
    lock_label = lock_tag.file
    # Also before the first pin creates it, so the hub follows once it exists.
    module_ctx.watch(lock_label)
    exists = module_ctx.path(lock_label).exists
    lock = json.decode(module_ctx.read(lock_label)) if exists else {"artifacts": {}}
    for file_id, a in lock["artifacts"].items():
        http_file(
            name = _repo_name(file_id),
            urls = [a["url"]],
            sha256 = a["sha256"],
            downloaded_file_path = a["file"],
        )
    http_archive(
        name = lock_tag.name + "_gradle",
        urls = ["https://services.gradle.org/distributions/gradle-%s-bin.zip" % _GRADLE_VERSION],
        sha256 = _GRADLE_SHA256,
        strip_prefix = "gradle-" + _GRADLE_VERSION,
        build_file_content = 'filegroup(name = "files", srcs = glob(["**"]), visibility = ["//visibility:public"])\n',
    )
    _hub(
        name = lock_tag.name,
        lock = lock_label if exists else None,
        platforms = lock_tag.platforms,
        link_pods_package = lock_tag.link_pods_package,
        pin_config = json.encode_indent(_pin_config(module_ctx, lock_tag), indent = " "),
        gradle = "@%s_gradle//:files" % lock_tag.name,
    )
    maven_libs_repository(
        name = "kmp_maven_libs",
        hub = lock_tag.name,
        modules = sorted([
            "%s %s" % (platform, coordinate)
            for platform, modules in lock.get("platforms", {}).items()
            for coordinate in modules
        ]),
    )
    return module_ctx.extension_metadata(reproducible = True)

maven = module_extension(
    implementation = _maven_impl,
    tag_classes = {
        "lock": tag_class(attrs = _LOCK_ATTRS | {
            "file": attr.label(mandatory = True, doc = "The lock: each artifact's URL and sha256, and per platform each module's files and dependencies."),
            "name": attr.string(default = "maven", doc = "Name of the hub repository."),
            "jvm_version": attr.int(default = 21, doc = "The Java version JVM and Android code targets: no library may need a newer one."),
        }),
        "repository": tag_class(
            doc = "A Maven repository to resolve from. Each artifact comes from the first declared repository that serves it.",
            attrs = {
                "name": attr.string(mandatory = True),
                "url": attr.string(mandatory = True),
                "groups": attr.string_list(doc = "Group prefixes the repository is asked for; empty for every group."),
            },
        ),
        "artifact": tag_class(
            doc = "A dependency the lock resolves, with everything it depends on, for each of `platforms`.",
            attrs = {
                "coordinates": attr.string(mandatory = True, doc = "group:module:version[:classifier]; Gradle's dynamic versions (1.2.+) resolve to the newest match."),
                "platforms": attr.string_list(mandatory = True, doc = "Lock platforms, built in (jvm, android, ios_arm64, ..., tools) or from maven.lock(platforms)."),
                "scope": attr.string(
                    default = "compile",
                    values = ["compile", "provided", "runtime"],
                    doc = "Which classpaths it is on, as in Maven: compile both, provided the compile one, runtime the runtime one. Kotlin/Native and tools have one resolution that takes every scope.",
                ),
                "excludes": attr.string_list(doc = "group:module of transitive dependencies to leave out on this path."),
                "bom": attr.bool(doc = "A platform (BOM): it constrains the versions of the other modules and adds none."),
            },
        ),
        "compile_version": tag_class(
            doc = "A lower version of a module to compile against than the one the platform runs with.",
            attrs = {
                "coordinates": attr.string(mandatory = True, doc = "group:module:version"),
                "platforms": attr.string_list(mandatory = True),
            },
        ),
        "omit_dependency": tag_class(
            doc = "Drops a dependency from a module's published metadata, e.g. one it declares but does not need.",
            attrs = {
                "module": attr.string(mandatory = True, doc = "group:module whose metadata declares the dependency."),
                "dependency": attr.string(mandatory = True, doc = "group:module of the dependency."),
            },
        ),
    },
)
