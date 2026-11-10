"""Builds the files of a Maven publication of a Kotlin module, as Gradle's maven-publish writes them.

  sources-jar --out <jar> [--src <source set> <file>]... [--srcjar <source set> <jar>]...
      A sources jar with each file under <source set>/<package path>/ (KGP's layout).
  merge-jar --out <jar> <jar>...
      One jar with the entries of all (the first wins), e.g. classes and resources.
  empty-jar --out <jar>
      A jar with only a manifest (Gradle's javadoc jar of a Kotlin-only module).
  resources-zip --out <zip> --package <package> --root <dir> [<file>]...
      Compose resources of a Kotlin/Native target: composeResources/<package>/...
  spec --plan <plan.json> --out <spec.json>
      The plan with the size and checksums of every file it names.
  repository --spec <spec.json>... --version <v> [--stable-status <file> --version-key <key>]
             --out <dir> --manifest <file>
      The POMs and Gradle module metadata of the specs in a Maven repository layout, and a manifest
      of every file of the repository (repository path, then the file's runfiles path).

Every archive is reproducible: fixed timestamps, sorted entries.
"""

import argparse
import hashlib
import json
import os
import re
import sys
import zipfile

# Gradle's reproducible archive timestamp.
_DATE = (1980, 2, 1, 0, 0, 0)
_MANIFEST = b"Manifest-Version: 1.0\r\n\r\n"
_PACKAGE = re.compile(rb"^\s*package\s+([A-Za-z_][\w.`]*)", re.M)


def _write_zip(out, entries):
    """entries: {name: bytes}; writes them sorted, with the parent directories, manifest first."""
    names = set()
    for name in entries:
        parts = name.split("/")[:-1]
        for i in range(1, len(parts) + 1):
            names.add("/".join(parts[:i]) + "/")
    names.update(entries)
    first = [n for n in ("META-INF/", "META-INF/MANIFEST.MF") if n in names]
    with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
        for name in first + sorted(names - set(first)):
            info = zipfile.ZipInfo(name, _DATE)
            if name.endswith("/"):
                info.external_attr = (0o40755 << 16) | 0x10
                z.writestr(info, b"")
            else:
                info.external_attr = 0o644 << 16
                info.compress_type = zipfile.ZIP_DEFLATED
                z.writestr(info, entries[name])


def _source_path(source_set, path):
    """Where a source file goes in a sources jar: its path below src/<source set>/<lang>/, or its
    package directory for generated files. Without a source set (a Kotlin/JVM module's jar) any
    source directory counts and no source set directory is added."""
    m = re.search(r"(^|/)src/%s/(kotlin|java)/" % (re.escape(source_set) if source_set else "[^/]+"), path)
    if m:
        return _prefix(source_set) + path[m.end() :]
    with open(path, "rb") as f:
        m = _PACKAGE.search(f.read())
    package = m.group(1).decode().replace("`", "").replace(".", "/") + "/" if m else ""
    return _prefix(source_set) + package + os.path.basename(path)


def _prefix(source_set):
    return source_set + "/" if source_set else ""


def sources_jar(args):
    entries = {"META-INF/MANIFEST.MF": _MANIFEST}
    for source_set, path in args.src or []:
        with open(path, "rb") as f:
            entries.setdefault(_source_path(source_set, path), f.read())
    for source_set, path in args.srcjar or []:
        with zipfile.ZipFile(path) as z:
            for info in z.infolist():
                if not info.is_dir() and not info.filename.startswith("META-INF/"):
                    entries.setdefault(_prefix(source_set) + info.filename, z.read(info))
    _write_zip(args.out, entries)


def merge_jar(args):
    entries = {"META-INF/MANIFEST.MF": _MANIFEST}
    for path in args.jars:
        with zipfile.ZipFile(path) as z:
            for info in z.infolist():
                if not info.is_dir() and info.filename != "META-INF/MANIFEST.MF":
                    entries.setdefault(info.filename, z.read(info))
    _write_zip(args.out, entries)


def empty_jar(args):
    _write_zip(args.out, {"META-INF/MANIFEST.MF": _MANIFEST})


def resources_zip(args):
    entries = {}
    root = args.root.rstrip("/") + "/"
    for path in args.files:
        rel = path[len(root) :] if path.startswith(root) else os.path.basename(path)
        with open(path, "rb") as f:
            entries["composeResources/%s/%s" % (args.package, rel)] = f.read()
    _write_zip(args.out, entries)
    if not entries:
        # Gradle keeps the package directory of a module without resources.
        with zipfile.ZipFile(args.out, "w") as z:
            for name in ("composeResources/", "composeResources/%s/" % args.package):
                info = zipfile.ZipInfo(name, _DATE)
                info.external_attr = (0o40755 << 16) | 0x10
                z.writestr(info, b"")


def _digests(path):
    algorithms = ("sha512", "sha256", "sha1", "md5")
    hashes = {a: hashlib.new(a) for a in algorithms}
    size = 0
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            size += len(chunk)
            for h in hashes.values():
                h.update(chunk)
    return dict(size=size, **{a: hashes[a].hexdigest() for a in algorithms})


def spec(args):
    with open(args.plan) as f:
        plan = json.load(f)
    for publication in plan["publications"]:
        for file in publication["files"]:
            file.update(_digests(file.pop("path")))
    with open(args.out, "w") as f:
        json.dump(plan, f, indent=1, sort_keys=True)


# Gradle's attributes of the variants of a Kotlin target, by the kind of target.
_LIBRARY = "library"


def _target_variants(kind, gradle_name, native_target):
    """[(variant name, attributes, role)] of a KMP target: role says which files and dependencies
    the variant has (api, runtime, sources, resources)."""
    base = {"org.gradle.jvm.environment": "non-jvm"}
    if kind == "jvm":
        base = {
            "org.gradle.jvm.environment": "standard-jvm",
            "org.gradle.libraryelements": "jar",
            "org.jetbrains.kotlin.platform.type": "jvm",
        }
        lib = {"org.gradle.libraryelements": "jar"}
    elif kind == "android":
        base = {"org.gradle.jvm.environment": "android", "org.jetbrains.kotlin.platform.type": "androidJvm"}
        lib = {"org.gradle.libraryelements": "aar"}
    elif kind == "native":
        base = dict(
            base,
            **{"org.jetbrains.kotlin.native.target": native_target, "org.jetbrains.kotlin.platform.type": "native"},
        )
        lib = {}
    elif kind == "js":
        base = dict(base, **{"org.jetbrains.kotlin.js.compiler": "ir", "org.jetbrains.kotlin.platform.type": "js"})
        lib = {}
    elif kind == "wasm":
        base = dict(base, **{"org.jetbrains.kotlin.platform.type": "wasm", "org.jetbrains.kotlin.wasm.target": "js"})
        lib = {}
    else:
        raise SystemExit("unknown target kind " + kind)
    jvm_like = kind in ("jvm", "android")
    api = dict(
        base, **lib, **{"org.gradle.category": _LIBRARY, "org.gradle.usage": "java-api" if jvm_like else "kotlin-api"}
    )
    runtime = dict(api, **{"org.gradle.usage": "java-runtime" if jvm_like else "kotlin-runtime"})
    sources = dict(
        base,
        **{
            "org.gradle.category": "documentation",
            "org.gradle.dependency.bundling": "external",
            "org.gradle.docstype": "sources",
            "org.gradle.usage": "java-runtime" if jvm_like else "kotlin-runtime",
        },
    )
    if jvm_like:
        sources["org.gradle.libraryelements"] = "jar"
    variants = [(gradle_name + "ApiElements-published", api, "api")]
    if kind != "native":
        variants.append((gradle_name + "RuntimeElements-published", runtime, "runtime"))
    variants.append((gradle_name + "SourcesElements-published", sources, "sources"))
    if kind == "native":
        resources = dict(
            base,
            **{
                "org.gradle.category": _LIBRARY,
                "org.gradle.dependency.bundling": "external",
                "org.gradle.libraryelements": "kotlin-multiplatformresources",
                "org.gradle.usage": "kotlin-multiplatformresources",
            },
        )
        variants.append((gradle_name + "ResourcesElements-published", resources, "resources"))
    return variants


def _java_variants(jvm_version):
    lib = {
        "org.gradle.category": _LIBRARY,
        "org.gradle.dependency.bundling": "external",
        "org.gradle.jvm.environment": "standard-jvm",
        "org.gradle.jvm.version": jvm_version,
        "org.gradle.libraryelements": "jar",
        "org.jetbrains.kotlin.platform.type": "jvm",
    }
    doc = {
        "org.gradle.category": "documentation",
        "org.gradle.dependency.bundling": "external",
        "org.gradle.usage": "java-runtime",
    }
    return [
        ("apiElements", dict(lib, **{"org.gradle.usage": "java-api"}), "api"),
        ("runtimeElements", dict(lib, **{"org.gradle.usage": "java-runtime"}), "runtime"),
        ("javadocElements", dict(doc, **{"org.gradle.docstype": "javadoc"}), "javadoc"),
        ("sourcesElements", dict(doc, **{"org.gradle.docstype": "sources"}), "sources"),
    ]


def _file_name(artifact, version, file):
    classifier = "-" + file["classifier"] if file["classifier"] else ""
    return "%s-%s%s.%s" % (artifact, version, classifier, file["extension"])


def _module_file(artifact, version, file):
    name = _file_name(artifact, version, file)
    return {
        "name": name,
        "url": name,
        "size": file["size"],
        "sha512": file["sha512"],
        "sha256": file["sha256"],
        "sha1": file["sha1"],
        "md5": file["md5"],
    }


def _dep_version(dep, version):
    return dep["version"] if dep["version"] is not None else version


def _module_deps(deps, version):
    out = []
    for dep in deps:
        entry = {"group": dep["group"], "module": dep["module"], "version": {"requires": _dep_version(dep, version)}}
        if entry not in out:
            out.append(entry)
    return out


def _pom(group, artifact, version, packaging, deps, pom, with_module):
    lines = [
        '<?xml version="1.0" encoding="UTF-8"?>',
        '<project xmlns="http://maven.apache.org/POM/4.0.0" xsi:schemaLocation="http://maven.apache.org/POM/4.0.0 https://maven.apache.org/xsd/maven-4.0.0.xsd" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">',
    ]
    if with_module:
        # Gradle only reads the .module file of a POM that carries this marker.
        lines += [
            "  <!-- This module was also published with a richer model, Gradle metadata,  -->",
            "  <!-- which should be used instead. Do not delete the following line which  -->",
            "  <!-- is to indicate to Gradle or any Gradle module metadata file consumer  -->",
            "  <!-- that they should prefer consuming it instead. -->",
            "  <!-- do_not_remove: published-with-gradle-metadata -->",
        ]
    lines += [
        "  <modelVersion>4.0.0</modelVersion>",
        "  <groupId>%s</groupId>" % _xml(group),
        "  <artifactId>%s</artifactId>" % _xml(artifact),
        "  <version>%s</version>" % _xml(version),
    ]
    if packaging:
        lines.append("  <packaging>%s</packaging>" % packaging)
    if pom.get("name"):
        lines.append("  <name>%s</name>" % _xml(pom["name"]))
    if pom.get("description"):
        lines.append("  <description>%s</description>" % _xml(pom["description"]))
    seen = set()
    rendered = []
    for dep, scope in deps:
        p = dep["pom"]
        key = (p["group"], p["artifact"])
        if key in seen:
            continue
        seen.add(key)
        rendered += [
            "    <dependency>",
            "      <groupId>%s</groupId>" % _xml(p["group"]),
            "      <artifactId>%s</artifactId>" % _xml(p["artifact"]),
            "      <version>%s</version>" % _xml(p["version"] if p["version"] is not None else version),
            "      <scope>%s</scope>" % scope,
            "    </dependency>",
        ]
    if rendered:
        lines += ["  <dependencies>"] + rendered + ["  </dependencies>"]
    lines.append("</project>")
    return "\n".join(lines) + "\n"


def _xml(text):
    return text.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


def _module_json(component, variants):
    return json.dumps({"formatVersion": "1.1", "component": component, "variants": variants}, indent=2) + "\n"


def _render(spec, version, write, add):
    """Writes the POMs and .module files of one spec with write(path, text) and lists every file
    of the publication with add(repository path, runfiles path or None for written files)."""
    group = spec["group"]
    base = group.replace(".", "/")
    pom_info = spec.get("pom") or {}
    by_role = {p["role"]: p for p in spec["publications"]}

    def files_of(publication, kind):
        return [f for f in publication["files"] if f["kind"] == kind]

    def publish(publication, packaging, pom_deps, module):
        artifact = publication["artifact"]
        directory = "%s/%s/%s" % (base, artifact, version)
        for file in publication["files"]:
            add("%s/%s" % (directory, _file_name(artifact, version, file)), file["short_path"])
        stem = "%s/%s-%s" % (directory, artifact, version)
        write(stem + ".module", module)
        write(stem + ".pom", _pom(group, artifact, version, packaging, pom_deps, pom_info, True))

    if spec["kind"] == "jvm":
        publication = by_role["jvm"]
        artifact = publication["artifact"]
        variants = []
        for name, attributes, role in _java_variants(spec["jvm_version"]):
            variant = {"name": name, "attributes": attributes}
            deps = {
                "api": publication["api"],
                "runtime": publication["api"] + publication["implementation"] + publication["runtime_only"],
            }.get(role)
            if deps:
                variant["dependencies"] = _module_deps(deps, version)
            kind = {"api": "main", "runtime": "main"}.get(role, role)
            variant["files"] = [_module_file(artifact, version, f) for f in files_of(publication, kind)]
            variants.append(variant)
        component = {
            "group": group,
            "module": artifact,
            "version": version,
            "attributes": {"org.gradle.status": "release"},
        }
        pom_deps = [(d, "compile") for d in publication["api"]] + [
            (d, "runtime") for d in publication["implementation"] + publication["runtime_only"]
        ]
        publish(publication, None, pom_deps, _module_json(component, variants))
        return

    root = by_role["root"]
    root_artifact = root["artifact"]
    root_component = {
        "group": group,
        "module": root_artifact,
        "version": version,
        "attributes": {"org.gradle.status": "release"},
    }
    root_variants = []
    sources = files_of(root, "sources")
    if sources:
        root_variants.append(
            {
                "name": "metadataSourcesElements",
                "attributes": {
                    "org.gradle.category": "documentation",
                    "org.gradle.dependency.bundling": "external",
                    "org.gradle.docstype": "sources",
                    "org.gradle.jvm.environment": "non-jvm",
                    "org.gradle.usage": "kotlin-runtime",
                    "org.jetbrains.kotlin.platform.type": "common",
                },
                "files": [_module_file(root_artifact, version, f) for f in sources],
            }
        )
    for publication in spec["publications"]:
        if publication["role"] == "root":
            continue
        artifact = publication["artifact"]
        kind = publication["target_kind"]
        variants = []
        for name, attributes, role in _target_variants(
            kind, publication["gradle_name"], publication.get("native_target")
        ):
            role_files = {
                "api": files_of(publication, "main") + files_of(publication, "cinterop"),
                "runtime": files_of(publication, "main"),
                "sources": files_of(publication, "sources"),
                "resources": files_of(publication, "resources"),
            }[role]
            if role == "resources" and not role_files:
                continue
            variant = {"name": name, "attributes": attributes}
            api = publication["api"]
            everything = api + publication["implementation"] + publication["runtime_only"]
            deps = {
                # A Kotlin/Native library compiles against everything its dependencies link.
                "api": everything if kind == "native" else api,
                "runtime": everything,
                "resources": everything,
            }.get(role)
            if deps:
                variant["dependencies"] = _module_deps(deps, version)
            variant["files"] = [_module_file(artifact, version, f) for f in role_files]
            variants.append(variant)
            root_variants.append(
                {
                    "name": name,
                    "attributes": attributes,
                    "available-at": {
                        "url": "../../%s/%s/%s-%s.module" % (artifact, version, artifact, version),
                        "group": group,
                        "module": artifact,
                        "version": version,
                    },
                }
            )
        component = {
            "url": "../../%s/%s/%s-%s.module" % (root_artifact, version, root_artifact, version),
            "group": group,
            "module": root_artifact,
            "version": version,
            "attributes": {"org.gradle.status": "release"},
        }
        if kind == "native":
            pom_deps = [
                (d, "compile") for d in publication["api"] + publication["implementation"] + publication["runtime_only"]
            ]
        else:
            pom_deps = [(d, "compile") for d in publication["api"]] + [
                (d, "runtime") for d in publication["implementation"] + publication["runtime_only"]
            ]
        packaging = {"android": "aar", "native": "klib", "js": "klib", "wasm": "klib"}.get(kind)
        publish(publication, packaging, pom_deps, _module_json(component, variants))
    # The root module's POM lists the root modules of its dependencies too.
    root_deps = [
        dict(d, pom={"group": d["group"], "artifact": d["module"], "version": d["version"]})
        for d in root["implementation"]
    ]
    publish(root, None, [(d, "runtime") for d in root_deps], _module_json(root_component, root_variants))


def repository(args):
    version = args.version
    if args.stable_status:
        with open(args.stable_status) as f:
            for line in f:
                key, _, value = line.rstrip("\n").partition(" ")
                if key == args.version_key and value:
                    version = value
    os.makedirs(args.out, exist_ok=True)
    manifest = []
    written = set()

    def write(path, text):
        target = os.path.join(args.out, path)
        os.makedirs(os.path.dirname(target), exist_ok=True)
        with open(target, "w") as f:
            f.write(text)
        manifest.append((path, None))
        written.add(path)

    def add(path, short_path):
        manifest.append((path, short_path))

    for spec_path in args.spec:
        with open(spec_path) as f:
            _render(json.load(f), version, write, add)
    paths = [p for p, _ in manifest]
    duplicates = sorted({p for p in paths if paths.count(p) > 1})
    if duplicates:
        raise SystemExit("published twice: " + ", ".join(duplicates))
    with open(args.manifest, "w") as f:
        f.write("version\t%s\n" % version)
        for path, short_path in sorted(manifest):
            f.write("%s\t%s\n" % (path, short_path if short_path else "@" + path))


def main(argv):
    parser = argparse.ArgumentParser()
    commands = parser.add_subparsers(dest="command", required=True)
    p = commands.add_parser("sources-jar")
    p.add_argument("--out", required=True)
    p.add_argument("--src", nargs=2, action="append")
    p.add_argument("--srcjar", nargs=2, action="append")
    p.set_defaults(run=sources_jar)
    p = commands.add_parser("merge-jar")
    p.add_argument("--out", required=True)
    p.add_argument("jars", nargs="+")
    p.set_defaults(run=merge_jar)
    p = commands.add_parser("empty-jar")
    p.add_argument("--out", required=True)
    p.set_defaults(run=empty_jar)
    p = commands.add_parser("resources-zip")
    p.add_argument("--out", required=True)
    p.add_argument("--package", required=True)
    p.add_argument("--root", required=True)
    p.add_argument("files", nargs="*")
    p.set_defaults(run=resources_zip)
    p = commands.add_parser("spec")
    p.add_argument("--plan", required=True)
    p.add_argument("--out", required=True)
    p.set_defaults(run=spec)
    p = commands.add_parser("repository")
    p.add_argument("--spec", action="append", required=True)
    p.add_argument("--version", required=True)
    p.add_argument("--stable-status")
    p.add_argument("--version-key")
    p.add_argument("--out", required=True)
    p.add_argument("--manifest", required=True)
    p.set_defaults(run=repository)
    args = parser.parse_args(argv)
    args.run(args)


if __name__ == "__main__":
    main(sys.argv[1:])
