"""kmp_publication and maven_repository: the Maven publications of modules built here.

kmp_library(publication = publication_options()) and kmp_jvm_module(publication = ...) declare
`<name>_publication`: what Gradle's maven-publish publishes for the module. For a Kotlin
Multiplatform module that is one Maven module per target (`<artifact>-jvm`, `-android`,
`-iosarm64`, `-wasm-js`, ...: the jar, AAR or klibs, a sources jar, POM and Gradle module metadata)
and the root module `<artifact>`, whose Gradle module metadata points Gradle at the target modules.
A Kotlin/JVM module publishes one Maven module with a jar, sources and javadoc jar.

The root module carries no common metadata (Gradle's `metadataApiElements`, the root `.jar`, and
each Kotlin/Native target's `-metadata.jar`): Bazel doesn't compile shared source sets to metadata
klibs. Consumers that compile a single platform resolve their target module through the root
module as with Gradle; Gradle builds compiling shared source sets of a consumer against the module
need that metadata.

maven_repository lays out publications as a Maven repository (version from a workspace status key
when stamping) and writes a manifest that a publishing tool uploads from.
"""

load("@rules_java//java/common:java_info.bzl", "JavaInfo")
load("//kotlin:providers.bzl", "ComposeResourcesInfo", "KlibInfo", "KtCompilationInfo")
load(":pom.bzl", "MavenCoordinatesInfo", "maven_coordinates_aspect")

KmpPublicationInfo = provider(
    doc = "The Maven publication of a module: a spec of its Maven modules and their files.",
    fields = {
        "spec": "File: JSON spec (see publication.py).",
        "files": "depset[File]: the files the spec publishes.",
    },
)

# Platform -> (Gradle target name, artifactId suffix, kind of target).
PUBLISHED_PLATFORMS = {
    "jvm": ("jvm", "jvm", "jvm"),
    "android": ("android", "android", "android"),
    "ios_arm64": ("iosArm64", "iosarm64", "native"),
    "ios_simulator_arm64": ("iosSimulatorArm64", "iossimulatorarm64", "native"),
    "ios_x64": ("iosX64", "iosx64", "native"),
    "macos_arm64": ("macosArm64", "macosarm64", "native"),
    "macos_x64": ("macosX64", "macosx64", "native"),
    "js": ("js", "js", "js"),
    "wasm_js": ("wasmJs", "wasm-js", "wasm"),
}

def publication_options(name = None, description = None, resources_package = None, jars = []):
    """Publishes a module to Maven (see kmp_publication).

    Args:
      name: The POM's <name>.
      description: The POM's <description>.
      resources_package: Res class package of a module that applies Compose resources without
        having any: its Kotlin/Native targets still publish an (empty) resources archive.
      jars: Jars whose entries the published JVM jar has too, e.g. an index of its classes.
    """
    return struct(name = name, description = description, resources_package = resources_package, jars = jars)

def platform_artifact(coordinates, platform):
    """group:artifact of a Kotlin Multiplatform module's target `platform`."""
    return "%s-%s" % (coordinates, PUBLISHED_PLATFORMS[platform][1])

def _dependency(info):
    """A dependency as the spec lists it: root coordinates for Gradle module metadata, the
    target's own module for the POM (Gradle's `available-at`)."""
    if info.coordinates:
        group, module, version = info.coordinates.split(":")
    else:
        group, module = info.module_name.split(":")
        version = None
    if info.available_at:
        parts = info.available_at.split(":")
        pom = {"group": parts[0], "artifact": parts[1], "version": parts[2] if len(parts) > 2 else version}
    else:
        pom = {"group": group, "artifact": module, "version": version}
    return {"group": group, "module": module, "version": version, "pom": pom}

def _own(ctx, target, info):
    """A dependency without coordinates in the module's own package is part of its artifact
    (e.g. its Compose resources jar)."""
    return not info.coordinates and not info.module_name and target.label.package == ctx.label.package and \
           target.label.repo_name == ctx.label.repo_name

def _deps_of(ctx, attr_dict, platform):
    out = []
    for target, platforms in attr_dict.items():
        if platform not in platforms.split(" "):
            continue
        info = target[MavenCoordinatesInfo]
        if _own(ctx, target, info):
            continue
        if not info.coordinates and not info.module_name:
            fail("%s has no Maven coordinates: tag it maven_coordinates=group:artifact:version" % target.label)
        dep = _dependency(info)
        if dep not in out:
            out.append(dep)
    return out

def _file(kind, f, classifier = None, extension = None):
    return {
        "kind": kind,
        "classifier": classifier,
        "extension": extension or f.extension,
        "path": f.path,
        "short_path": f.short_path,
    }

def _sources_jar(ctx, name, srcs):
    """srcs: [(source set, File, is_srcjar)]."""
    out = ctx.actions.declare_file("%s/%s-sources.jar" % (ctx.label.name, name))
    args = ctx.actions.args()
    args.add("sources-jar")
    args.add("--out", out)
    for source_set, f, srcjar in srcs:
        args.add_all("--srcjar" if srcjar else "--src", [source_set, f])
    ctx.actions.run(
        executable = ctx.executable._tool,
        arguments = [args],
        inputs = [f for _, f, _ in srcs],
        outputs = [out],
        mnemonic = "KmpSourcesJar",
        progress_message = "Packaging sources of %{label}",
    )
    return out

def _sources_of(ctx, platform):
    srcs = []
    for target, value in ctx.attr.srcs.items():
        for entry in value.split(" "):
            p, _, source_set = entry.partition("=")
            if p != platform:
                continue
            for f in target.files.to_list():
                srcs.append((source_set, f, f.extension in ("srcjar", "jar")))
    return srcs

def _gradle_jvm_version(compilation):
    """org.gradle.jvm.version of a Kotlin/JVM module: the JVM target it was compiled for."""
    jvm_target = compilation[KtCompilationInfo].jvm_target
    return int(jvm_target.removeprefix("1."))

def _kmp_publication_impl(ctx):
    group, artifact = ctx.attr.coordinates.split(":")
    tool = ctx.executable._tool
    files = []
    publications = []

    def add(kind, f, classifier = None, extension = None):
        files.append(f)
        return _file(kind, f, classifier, extension)

    artifacts = {p: t for t, p in ctx.attr.artifacts.items()}
    cinterops = {}
    for t, p in ctx.attr.cinterops.items():
        cinterops.setdefault(p, []).append(t)

    for platform in ctx.attr.platforms:
        gradle_name, suffix, kind = PUBLISHED_PLATFORMS[platform]
        name = artifact if ctx.attr.kind == "jvm" else "%s-%s" % (artifact, suffix)
        target = artifacts[platform]
        pfiles = []
        if kind in ("jvm",):
            jar = ctx.actions.declare_file("%s/%s.jar" % (ctx.label.name, name))
            class_jars = [o.class_jar for o in target[JavaInfo].java_outputs] + [
                o.class_jar
                for t, platforms in ctx.attr.runtime_only.items()
                if platform in platforms.split(" ") and _own(ctx, t, t[MavenCoordinatesInfo])
                for o in t[JavaInfo].java_outputs
            ] + ctx.files.jars
            ctx.actions.run(
                executable = tool,
                arguments = ["merge-jar", "--out", jar.path] + [j.path for j in class_jars],
                inputs = class_jars,
                outputs = [jar],
                mnemonic = "KmpPublicationJar",
                progress_message = "Packaging the jar of %{label}",
            )
            pfiles.append(add("main", jar))
        elif kind == "android":
            pfiles.append(add("main", target.files.to_list()[0], extension = "aar"))
        else:
            pfiles.append(add("main", target[KlibInfo].klibs[0], extension = "klib"))
            for c in cinterops.get(platform, []):
                info = c[KlibInfo]
                cname = info.module_name.rsplit(":", 1)[-1]
                # Gradle names a pod's bindings after the pod, with `-` as `_`.
                cname = cname.split("-cinterop-", 1)[-1].replace("-", "_")
                pfiles.append(add("cinterop", info.klibs[0], classifier = "cinterop-" + cname, extension = "klib"))
            if kind == "native" and (ctx.attr.compose_resources or ctx.attr.resources_package):
                res = ctx.attr.compose_resources[ComposeResourcesInfo] if ctx.attr.compose_resources else struct(
                    package = ctx.attr.resources_package,
                    root = ".",
                    files = [],
                )
                zip = ctx.actions.declare_file("%s/%s-kotlin_resources.zip" % (ctx.label.name, name))
                args = ctx.actions.args()
                args.add_all(["resources-zip", "--out", zip, "--package", res.package, "--root", res.root])
                args.add_all(res.files)
                ctx.actions.run(
                    executable = tool,
                    arguments = [args],
                    inputs = res.files,
                    outputs = [zip],
                    mnemonic = "KmpResourcesZip",
                )
                pfiles.append(add("resources", zip, classifier = "kotlin_resources.kotlin_resources", extension = "zip"))
        pfiles.append(add("sources", _sources_jar(ctx, name, _sources_of(ctx, platform)), classifier = "sources", extension = "jar"))
        if ctx.attr.kind == "jvm":
            javadoc = ctx.actions.declare_file("%s/%s-javadoc.jar" % (ctx.label.name, name))
            ctx.actions.run(
                executable = tool,
                arguments = ["empty-jar", "--out", javadoc.path],
                outputs = [javadoc],
                mnemonic = "KmpJavadocJar",
            )
            pfiles.append(add("javadoc", javadoc, classifier = "javadoc", extension = "jar"))
        publications.append({
            "role": "jvm" if ctx.attr.kind == "jvm" else "target",
            "artifact": name,
            "gradle_name": gradle_name,
            "target_kind": kind,
            "native_target": platform if kind == "native" else None,
            "files": pfiles,
            "api": _deps_of(ctx, ctx.attr.api, platform),
            "implementation": [d for d in _deps_of(ctx, ctx.attr.implementation, platform) if d not in _deps_of(ctx, ctx.attr.api, platform)],
            "runtime_only": _deps_of(ctx, ctx.attr.runtime_only, platform),
        })

    if ctx.attr.kind == "kmp":
        rfiles = [add("sources", _sources_jar(ctx, artifact, _sources_of(ctx, "root")), classifier = "sources", extension = "jar")]
        tooling = ctx.actions.declare_file("%s/%s-kotlin-tooling-metadata.json" % (ctx.label.name, artifact))
        ctx.actions.write(tooling, json.encode_indent({
            "schemaVersion": "1.1.0",
            "buildSystem": "Bazel",
            "buildPlugin": "rules_kmp",
            "buildPluginVersion": ctx.attr.kotlin_version,
            "projectSettings": {"isHmppEnabled": True, "isCompatibilityMetadataVariantEnabled": False, "isKPMEnabled": False},
            "projectTargets": [{"platformType": PUBLISHED_PLATFORMS[p][2]} for p in ctx.attr.platforms],
        }, indent = "  ") + "\n")
        rfiles.append(add("tooling", tooling, classifier = "kotlin-tooling-metadata", extension = "json"))
        publications.append({
            "role": "root",
            "artifact": artifact,
            "files": rfiles,
            "api": [],
            "implementation": _deps_of(ctx, ctx.attr.root_deps, "root"),
            "runtime_only": [],
        })

    plan = ctx.actions.declare_file(ctx.label.name + ".plan.json")
    ctx.actions.write(plan, json.encode({
        "group": group,
        "artifact": artifact,
        "kind": ctx.attr.kind,
        "jvm_version": _gradle_jvm_version(artifacts["jvm"]) if ctx.attr.kind == "jvm" else None,
        "pom": {"name": ctx.attr.pom_name, "description": ctx.attr.pom_description},
        "publications": publications,
    }))
    spec = ctx.actions.declare_file(ctx.label.name + ".json")
    ctx.actions.run(
        executable = tool,
        arguments = ["spec", "--plan", plan.path, "--out", spec.path],
        inputs = [plan] + files,
        outputs = [spec],
        mnemonic = "KmpPublicationSpec",
        progress_message = "Hashing the publication of %{label}",
    )
    return [
        DefaultInfo(files = depset([spec] + files)),
        KmpPublicationInfo(spec = spec, files = depset(files)),
    ]

_DEPS_ATTR = dict(
    aspects = [maven_coordinates_aspect],
    doc = "Dependency -> the space-separated platforms it is a dependency of.",
)

kmp_publication = rule(
    implementation = _kmp_publication_impl,
    doc = "The Maven publication of a kmp_library or kmp_jvm_module (see the file's doc).",
    attrs = {
        "coordinates": attr.string(mandatory = True, doc = "group:artifact of the (root) module."),
        "kind": attr.string(mandatory = True, values = ["kmp", "jvm"]),
        "platforms": attr.string_list(mandatory = True, doc = "Published platforms, in Gradle's target order."),
        "artifacts": attr.label_keyed_string_dict(doc = "Compilation (jvm), kmp_android_aar (android) or klib target -> its platform."),
        "cinterops": attr.label_keyed_string_dict(providers = [KlibInfo], doc = "cinterop klib -> its platform."),
        "srcs": attr.label_keyed_string_dict(
            allow_files = True,
            doc = "Sources -> space-separated `<platform>=<source set>` (platform `root` for the root module's sources jar).",
        ),
        "api": attr.label_keyed_string_dict(**_DEPS_ATTR),
        "implementation": attr.label_keyed_string_dict(**_DEPS_ATTR),
        "runtime_only": attr.label_keyed_string_dict(**_DEPS_ATTR),
        "root_deps": attr.label_keyed_string_dict(
            aspects = [maven_coordinates_aspect],
            doc = "Dependencies of the root module's POM (value `root`).",
        ),
        "compose_resources": attr.label(providers = [ComposeResourcesInfo]),
        "resources_package": attr.string(doc = "See publication_options."),
        "jars": attr.label_list(allow_files = [".jar"], doc = "See publication_options."),
        "kotlin_version": attr.string(),
        "pom_name": attr.string(),
        "pom_description": attr.string(),
        "_tool": attr.label(default = "//maven:publication", executable = True, cfg = "exec"),
    },
    provides = [KmpPublicationInfo],
)

def _maven_repository_impl(ctx):
    out = ctx.actions.declare_directory(ctx.label.name)
    manifest = ctx.actions.declare_file(ctx.label.name + ".manifest")
    specs = [p[KmpPublicationInfo].spec for p in ctx.attr.publications]
    args = ctx.actions.args()
    args.add("repository")
    args.add_all(specs, before_each = "--spec")
    args.add("--version", ctx.attr.version)
    inputs = list(specs)
    if ctx.attr.stamp and ctx.attr.version_key:
        args.add("--stable-status", ctx.info_file)
        args.add("--version-key", ctx.attr.version_key)
        inputs.append(ctx.info_file)
    args.add("--out", out.path)
    args.add("--manifest", manifest)
    ctx.actions.run(
        executable = ctx.executable._tool,
        arguments = [args],
        inputs = inputs,
        outputs = [out, manifest],
        mnemonic = "MavenRepository",
        progress_message = "Writing the POMs and module metadata of %{label}",
    )
    files = depset([out, manifest], transitive = [p[KmpPublicationInfo].files for p in ctx.attr.publications])
    return [DefaultInfo(files = depset([out, manifest]), runfiles = ctx.runfiles(transitive_files = files))]

_maven_repository = rule(
    implementation = _maven_repository_impl,
    attrs = {
        "publications": attr.label_list(providers = [KmpPublicationInfo], mandatory = True),
        "version": attr.string(mandatory = True),
        "version_key": attr.string(),
        "stamp": attr.bool(),
        "_tool": attr.label(default = "//maven:publication", executable = True, cfg = "exec"),
    },
)

def maven_repository(name, publications, version, version_key = None, **kwargs):
    """The publications as a Maven repository: `<name>` (POMs and .module files) and
    `<name>.manifest` (every file of the repository: its path, then its runfiles path, or `@path`
    for a file of `<name>`; first line `version <version>`).

    Args:
      name: Target name.
      publications: kmp_publication targets.
      version: The version of every module.
      version_key: Workspace status key whose value replaces `version` in stamped builds.
      **kwargs: Common attributes.
    """
    _maven_repository(
        name = name,
        publications = publications,
        version = version,
        version_key = version_key,
        stamp = select({
            Label("//maven:stamped"): True,
            "//conditions:default": False,
        }),
        **kwargs
    )
