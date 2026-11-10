"""maven_pom: the POM of an artifact built here, with Maven coordinates for its dependencies."""

MavenCoordinatesInfo = provider(
    doc = "The Maven module a dependency is published as.",
    fields = {
        "coordinates": "group:artifact:version of a Maven artifact, or None.",
        "module_name": "group:artifact of a Kotlin module built here (a kmp_library's module_name), or None.",
        "available_at": "The module of the platform's own artifact, where `coordinates` or `module_name` is a Kotlin Multiplatform root module (Gradle's `available-at`): group:artifact:version, or group:artifact for a module built here; None otherwise.",
    },
)

MavenPublicationInfo = provider(
    doc = "An artifact to publish and the direct runtime dependencies its POM lists.",
    fields = {
        "file": "File: the artifact.",
        "packaging": "The POM packaging, e.g. aar or jar.",
        "dependencies": "list of MavenCoordinatesInfo, in declaration order.",
        "unpublished": "list of Labels: dependencies without Maven coordinates, which no POM can list.",
    },
)

_NONE = MavenCoordinatesInfo(coordinates = None, module_name = None, available_at = None)

def _forwarded(target, attr):
    """The info of what a wrapper target stands for: a kmp_library's Android target is an
    android_library that exports its Kotlin compilation (or, for a JVM-only module, the rewrapped
    JVM jar), a pinned AAR one that exports its aar_import."""
    lib = getattr(attr, "lib", None)
    if lib and MavenCoordinatesInfo in lib:
        return lib[MavenCoordinatesInfo]
    for export in getattr(attr, "exports", []):
        if export.label.name in [target.label.name + s for s in ("_kt", "_jar", "_aar")] and MavenCoordinatesInfo in export:
            return export[MavenCoordinatesInfo]
    return None

def _maven_coordinates_aspect_impl(target, ctx):
    attr = ctx.rule.attr
    tags = getattr(attr, "tags", [])
    forwarded = _forwarded(target, attr)
    available_at = getattr(attr, "available_at", None) or getattr(attr, "maven_platform_artifact", None) or None
    for tag in tags:
        if tag.startswith("maven_available_at="):
            available_at = tag[len("maven_available_at="):]
    if not available_at and forwarded:
        available_at = forwarded.available_at
    for tag in tags:
        if tag.startswith("maven_coordinates="):
            return [MavenCoordinatesInfo(coordinates = tag[len("maven_coordinates="):], module_name = None, available_at = available_at)]
    coordinates = getattr(attr, "coordinates", None)
    if coordinates:
        return [MavenCoordinatesInfo(coordinates = coordinates, module_name = None, available_at = available_at)]
    module_name = getattr(attr, "maven_artifact", None) or getattr(attr, "module_name", None)
    if module_name:
        return [MavenCoordinatesInfo(coordinates = None, module_name = module_name, available_at = available_at)]
    return [forwarded or _NONE]

maven_coordinates_aspect = aspect(
    implementation = _maven_coordinates_aspect_impl,
    doc = """Finds the Maven module of a dependency: its `maven_coordinates=` tag (as in
rules_jvm_external), the coordinates of a pinned Maven artifact, or the module name of a Kotlin
module built here.""",
    attr_aspects = ["exports", "lib"],
)

def maven_dependencies(deps):
    """MavenPublicationInfo's `dependencies` and `unpublished` of `deps` (which carry maven_coordinates_aspect)."""
    out = []
    unpublished = []
    seen = {}
    for dep in deps:
        info = dep[MavenCoordinatesInfo]
        if not info.coordinates and not info.module_name:
            unpublished.append(dep.label)
            continue
        key = (info.coordinates, info.module_name)
        if key not in seen:
            seen[key] = True
            out.append(info)
    return struct(dependencies = out, unpublished = unpublished)

def _xml(text):
    return text.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")

def _maven_pom_impl(ctx):
    publication = ctx.attr.artifact[MavenPublicationInfo]
    if publication.unpublished:
        fail("%s has no Maven coordinates: tag it maven_coordinates=group:artifact:version" % publication.unpublished[0])
    group, artifact, version = ctx.attr.coordinates.split(":")
    lines = [
        '<?xml version="1.0" encoding="UTF-8"?>',
        '<project xmlns="http://maven.apache.org/POM/4.0.0" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xsi:schemaLocation="http://maven.apache.org/POM/4.0.0 https://maven.apache.org/xsd/maven-4.0.0.xsd">',
        "  <modelVersion>4.0.0</modelVersion>",
        "  <groupId>%s</groupId>" % _xml(group),
        "  <artifactId>%s</artifactId>" % _xml(artifact),
        "  <version>%s</version>" % _xml(version),
        "  <packaging>%s</packaging>" % publication.packaging,
    ]
    if publication.dependencies:
        lines.append("  <dependencies>")
        for dep in publication.dependencies:
            if dep.coordinates:
                parts = dep.coordinates.split(":")
                if len(parts) != 3:
                    fail("%s: expected group:artifact:version" % dep.coordinates)
            else:
                if not ctx.attr.module_version:
                    fail("%s is built here; maven_pom needs module_version to publish against it" % dep.module_name)
                parts = dep.module_name.split(":") + [ctx.attr.module_version]
            lines += [
                "    <dependency>",
                "      <groupId>%s</groupId>" % _xml(parts[0]),
                "      <artifactId>%s</artifactId>" % _xml(parts[1]),
                "      <version>%s</version>" % _xml(parts[2]),
                "      <scope>%s</scope>" % ctx.attr.scope,
                "    </dependency>",
            ]
        lines.append("  </dependencies>")
    lines.append("</project>")
    out = ctx.actions.declare_file(ctx.label.name + ".pom")
    ctx.actions.write(out, "\n".join(lines) + "\n")
    return [DefaultInfo(files = depset([out]))]

maven_pom = rule(
    implementation = _maven_pom_impl,
    doc = "Writes the POM of `artifact` (e.g. a kmp_android_aar) published as `coordinates`.",
    attrs = {
        "artifact": attr.label(mandatory = True, providers = [MavenPublicationInfo]),
        "coordinates": attr.string(mandatory = True, doc = "group:artifact:version of the publication."),
        "module_version": attr.string(doc = "The version the Kotlin modules built here are published with."),
        "scope": attr.string(default = "runtime", values = ["compile", "runtime"], doc = "The scope of every dependency."),
    },
)
