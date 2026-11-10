"""Builds the lock that @rules_kmp//maven:extension.bzl reads from resolved Gradle graphs.

Each platform has a compile and a runtime resolution (only one for Kotlin/Native and tools). A
module gets the highest version either resolved; its deps are the edges of the compile graph, its
runtime_deps the further edges of the runtime graph.
"""

import collections
import functools
import os
import posixpath
import re
import urllib.parse
import zipfile

LOCK_VERSION = 1

Node = collections.namedtuple("Node", ["version", "deps", "files"])


# Gradle's special qualifiers; any other qualifier ranks 1 and compares alphabetically.
_QUALIFIER_RANKS = {"dev": 0, "rc": 2, "snapshot": 3, "final": 4, "ga": 5, "release": 6, "sp": 7}


def _compare_versions(a, b):
    """Gradle's version order: 1.0-rc1 < 1.0 < 1.0.1, 1.0-alpha < 1.0-beta, dev below other qualifiers."""
    pa, pb = re.findall(r"\d+|[^\d.\-_+]+", a), re.findall(r"\d+|[^\d.\-_+]+", b)
    for x, y in zip(pa, pb):
        if x.isdigit() and y.isdigit():
            if int(x) != int(y):
                return -1 if int(x) < int(y) else 1
        elif x.isdigit() != y.isdigit():
            return 1 if x.isdigit() else -1
        elif x != y:
            kx = (_QUALIFIER_RANKS.get(x.lower(), 1), x)
            ky = (_QUALIFIER_RANKS.get(y.lower(), 1), y)
            return -1 if kx < ky else 1
    if len(pa) == len(pb):
        return 0
    longer, sign = (pa, 1) if len(pa) > len(pb) else (pb, -1)
    return sign if longer[min(len(pa), len(pb))].isdigit() else -sign


version_key = functools.cmp_to_key(_compare_versions)


def module_nodes(result):
    """group:module -> Node of each external module of a resolution."""
    by_id = {c["id"]: c for c in result["components"]}
    files = {}
    for a in result["artifacts"]:
        files.setdefault(a["component"], {})[os.path.basename(a["file"])] = a["file"]
    nodes = {}
    for c in result["components"]:
        if "group" not in c:
            continue
        ga = "%s:%s" % (c["group"], c["module"])
        deps = set()
        for d in c["deps"]:
            t = by_id.get(d["selected"])
            if d["constraint"] or t is None or "group" not in t:
                continue
            dga = "%s:%s" % (t["group"], t["module"])
            if dga != ga:
                deps.add(dga)
        nodes[ga] = Node(c["version"], deps, files.get(c["id"], {}))
    return nodes


def platform_modules(compile_nodes, runtime_nodes):
    """Merges a platform's compile and runtime graphs: group:module -> version, files and edges."""
    modules = {}
    for ga in sorted(set(compile_nodes) | set(runtime_nodes)):
        c, r = compile_nodes.get(ga), runtime_nodes.get(ga)
        version = max((n.version for n in (c, r) if n), key=version_key)
        deps = set(c.deps) if c and c.version == version else set()
        runtime_deps = (set(r.deps) if r and r.version == version else set()) - deps
        files = {}
        for n in (c, r):
            if n and n.version == version:
                files.update(n.files)
        modules[ga] = {"version": version, "deps": deps, "runtime_deps": runtime_deps, "files": files}
    for entry in modules.values():
        entry["deps"] = sorted(d for d in entry["deps"] if d in modules)
        entry["runtime_deps"] = sorted(d for d in entry["runtime_deps"] if d in modules)
    return modules


def apply_compile_versions(modules, pinned):
    """Records the version a module compiles against where it differs from the one it runs with.

    Args:
      modules: platform_modules() of the platform.
      pinned: group:module -> Node of the pinned compile version (resolved without dependencies).
    """
    for ga, node in sorted(pinned.items()):
        entry = modules.get(ga)
        if entry and node.version != entry["version"] and node.files:
            entry["compile_version"] = node.version
            entry["compile_files"] = node.files


def klib_manifest(path):
    with zipfile.ZipFile(path) as z:
        name = next(n for n in z.namelist() if n.endswith("default/manifest"))
        text = z.read(name).decode()
    props = {}
    for line in text.splitlines():
        if "=" in line and not line.startswith("#"):
            k, v = line.split("=", 1)
            props[k.strip()] = v.strip().replace("\\:", ":")
    return props


def add_klib_manifest_edges(modules, manifests, log):
    """Adds the dependencies a klib's manifest declares but its Maven metadata leaves out.

    Some libraries (e.g. compose-icons) publish only kotlin-stdlib and rely on consumers bringing
    Compose; caching a klib for Kotlin/Native needs every library it was compiled against.

    Args:
      modules: platform_modules() of a Kotlin/Native platform.
      manifests: group:module -> the manifests of its klibs.
      log: Called with a message for every edge added.
    """
    owner, names, depends = {}, {}, {}
    for ga, ms in sorted(manifests.items()):
        for m in ms:
            # Old Compose builds publish the same library under a second artifact id
            # (-uikitsimarm64 next to -iossimulatorarm64); the newest one is what gets linked.
            current = owner.get(m["unique_name"])
            if current is None or version_key(modules[ga]["version"]) > version_key(modules[current]["version"]):
                owner[m["unique_name"]] = ga
            names.setdefault(ga, []).append(m["unique_name"])
            depends.setdefault(ga, []).extend(m.get("depends", "").split())

    def reachable(start):
        seen, stack = set(), [start]
        while stack:
            for d in modules.get(stack.pop(), {}).get("deps", []):
                if d not in seen:
                    seen.add(d)
                    stack.append(d)
        return seen

    for ga, deps in sorted(depends.items()):
        if any(owner[n] != ga for n in names[ga]):
            continue
        missing = sorted({owner[n] for n in deps if n in owner and owner[n] != ga} - reachable(ga))
        if missing:
            modules[ga]["deps"] = sorted(modules[ga]["deps"] + missing)
            log("added klib manifest edges %s -> %s" % (ga, ", ".join(missing)))


def klib_frameworks(manifest):
    """The frameworks a klib's linkerOpts ask ld for."""
    opts = manifest.get("linkerOpts", "").split()
    return [opts[i + 1] for i, o in enumerate(opts[:-1]) if o in ("-framework", "-weak_framework")]


def add_pod_links(modules, manifests, in_sdk):
    """Records the frameworks outside the Apple SDK that a klib's linkerOpts need (link_pods).

    Every binary that links the klib then links them too, e.g. the Sentry pod for
    sentry-kotlin-multiplatform's bindings.

    Args:
      modules: platform_modules() of a Kotlin/Native platform.
      manifests: group:module -> the manifests of its klibs.
      in_sdk: Whether a framework is part of the platform's SDK.
    """
    for ga, ms in sorted(manifests.items()):
        pods = {f for m in ms for f in klib_frameworks(m) if not in_sdk(f)}
        if pods:
            modules[ga]["link_pods"] = sorted(pods)


QUARKUS_DESCRIPTOR = "META-INF/quarkus-extension.properties"


def _unescape(text):
    return re.sub(r"\\(u[0-9a-fA-F]{4}|.)", lambda m: chr(int(m.group(1)[1:], 16)) if len(m.group(1)) == 5
                  else {"n": "\n", "t": "\t", "r": "\r", "f": "\f"}.get(m.group(1), m.group(1)), text)


def java_properties(text):
    """The entries of a java.util.Properties file: comments, escapes and continued lines."""
    props = {}
    logical = ""
    for raw in text.splitlines():
        line = raw.lstrip()
        if not logical and (not line or line[0] in "#!"):
            continue
        trailing = len(line) - len(line.rstrip("\\"))
        if trailing % 2:
            logical += line[:-1]
            continue
        logical += line
        m = re.match(r"((?:\\.|[^=:\s\\])*)\s*[=:]?\s*(.*)$", logical)
        props[_unescape(m.group(1))] = _unescape(m.group(2))
        logical = ""
    return props


def _module_coordinates(coords):
    """group:module:version[:classifier] of a Quarkus descriptor's group:artifact[:classifier:type]:version."""
    parts = coords.split(":")
    if len(parts) == 3:
        return coords
    if len(parts) == 5:
        group, artifact, classifier, _, version = parts
        return ":".join([group, artifact, version] + ([classifier] if classifier else []))
    raise ValueError("unexpected coordinates in a Quarkus extension descriptor: " + coords)


def quarkus_descriptor(path):
    """The Quarkus extension descriptor of a jar, or None: deployment module, conditional
    dependencies (group:module:version) and the modules a conditional dependency itself needs on the
    classpath to be added (group:module)."""
    with zipfile.ZipFile(path) as z:
        if QUARKUS_DESCRIPTOR not in z.namelist():
            return None
        props = java_properties(z.read(QUARKUS_DESCRIPTOR).decode())
    deployment = props.get("deployment-artifact")
    return {
        "deployment": _module_coordinates(deployment) if deployment else None,
        "conditional": [_module_coordinates(c) for c in props.get("conditional-dependencies", "").split()],
        "condition": sorted(set(re.split(r"[\s,]+", props.get("dependency-condition", "").strip())) - {""}),
    }


def quarkus_extensions(modules):
    """group:module -> quarkus_descriptor() of each Quarkus extension among a JVM platform's modules.

    A Quarkus extension is a runtime module whose jar has META-INF/quarkus-extension.properties; its
    deployment module holds the build steps that run when an application is packaged.

    Args:
      modules: platform_modules() of a JVM platform.
    """
    out = {}
    for ga, entry in sorted(modules.items()):
        for name, path in sorted(entry["files"].items()):
            if name.endswith(".jar"):
                descriptor = quarkus_descriptor(path)
                if descriptor:
                    out[ga] = descriptor
    return out


def break_cycles(modules, log):
    """Removes back edges so the dependency graph is acyclic (Bazel forbids cycles)."""
    state = {}

    def edges(ga):
        return iter(sorted(set(modules[ga]["deps"] + modules[ga]["runtime_deps"])))

    for root in sorted(modules):
        if root in state:
            continue
        stack = [(root, edges(root))]
        state[root] = "active"
        while stack:
            node, it = stack[-1]
            nxt = next(it, None)
            if nxt is None:
                state[node] = "done"
                stack.pop()
                continue
            if state.get(nxt) == "active":
                for key in ("deps", "runtime_deps"):
                    if nxt in modules[node][key]:
                        modules[node][key].remove(nxt)
                log("broke dependency cycle edge %s -> %s" % (node, nxt))
            elif nxt not in state:
                state[nxt] = "active"
                stack.append((nxt, edges(nxt)))


# What makes two entries of a module resolve the same: same jars, same dependencies.
_RESOLUTION = ("version", "deps", "runtime_deps", "compile_version", "link_pods",
               "quarkus_deployment", "quarkus_conditional", "quarkus_condition")


def _same_resolution(a, b):
    return (all(a.get(k) == b.get(k) for k in _RESOLUTION)
            and sorted(a["files"]) == sorted(b["files"])
            and sorted(a.get("compile_files", {})) == sorted(b.get("compile_files", {})))


def alias_overlays(platforms, overlays):
    """Points an overlay platform's modules that resolve exactly as on its base platform at the base's
    targets. The others keep their own entries: an overlay runs and compiles against what it resolved.

    Args:
      platforms: platform -> group:module -> entry.
      overlays: overlay platform -> its base platform.
    """
    for overlay, base_name in sorted(overlays.items()):
        base = platforms.get(base_name, {})
        modules = platforms.get(overlay, {})
        for ga, entry in sorted(modules.items()):
            b = base.get(ga)
            if b and "alias" not in b and _same_resolution(b, entry):
                modules[ga] = {"alias": base_name}


Artifact = collections.namedtuple("Artifact", ["group", "module", "version", "name", "path"])


def lock_entries(platforms):
    """The lock's platforms, and the artifact files their entries name.

    Args:
      platforms: platform -> group:module -> entry, with files and compile_files as name -> path,
        after alias_overlays().

    Returns:
      (platform -> group:module -> lock entry, file id -> Artifact).
    """
    artifacts = {}
    out = {}
    for platform, modules in sorted(platforms.items()):
        pout = {}
        for ga, entry in sorted(modules.items()):
            if "alias" in entry:
                pout[ga] = entry
                continue
            group, module = ga.split(":", 1)

            def file_ids(version, files):
                ids = []
                for name, path in sorted(files.items()):
                    fid = "%s:%s:%s" % (ga, version, name)
                    artifacts[fid] = Artifact(group, module, version, name, path)
                    ids.append(fid)
                return ids

            e = {"version": entry["version"], "files": file_ids(entry["version"], entry["files"]),
                 "deps": entry["deps"], "runtime_deps": entry["runtime_deps"]}
            if "compile_version" in entry:
                e["compile_version"] = entry["compile_version"]
                e["compile_files"] = file_ids(entry["compile_version"], entry["compile_files"])
            if "link_pods" in entry:
                e["link_pods"] = entry["link_pods"]
            for key in ("quarkus_deployment", "quarkus_conditional", "quarkus_condition"):
                if key in entry:
                    e[key] = entry[key]
            pout[ga] = e
        out[platform] = pout
    return out, artifacts


def publication_versions(entries, infos):
    """Files the module metadata of one version publishes under another, with that version.

    Guava's 33.5.0-jre metadata gives Android consumers ../33.5.0-android/guava-33.5.0-android.jar:
    the file's coordinates are 33.5.0-android, and so are those of an entry that uses only such
    files. The URL loses its "..".

    Args:
      entries: platform -> group:module -> lock entry (see lock_entries).
      infos: file id -> {"url", "sha256", "file"} (see pin.artifact_infos).

    Returns:
      (entries, infos) with the files and versions moved.
    """
    renamed = {}
    out_infos = {}
    for fid, info in infos.items():
        group, module, version, name = fid.split(":", 3)
        url = urllib.parse.urlsplit(info["url"])
        path = posixpath.normpath(url.path)
        parts = path.split("/")
        published = parts[-2] if len(parts) > 3 and parts[-3] == module and parts[-1] == name else version
        if published != version and path.endswith("/%s/%s/%s/%s" % (group.replace(".", "/"), module, published, name)):
            new = "%s:%s:%s:%s" % (group, module, published, name)
            renamed[fid] = new
            info = dict(info, url=urllib.parse.urlunsplit(url._replace(path=path)))
            fid = new
        if fid in out_infos and out_infos[fid]["sha256"] != info["sha256"]:
            raise SystemExit("%s has two sha256s: %s and %s" % (fid, out_infos[fid]["sha256"], info["sha256"]))
        out_infos[fid] = info
    out = {}
    for platform, modules in entries.items():
        pout = {}
        for ga, entry in modules.items():
            entry = dict(entry)
            for files_key, version_key_ in (("files", "version"), ("compile_files", "compile_version")):
                if files_key not in entry:
                    continue
                files = [renamed.get(f, f) for f in entry[files_key]]
                versions = {f.split(":", 3)[2] for f in files}
                if any(f in renamed for f in entry[files_key]) and len(versions) == 1:
                    entry[version_key_] = versions.pop()
                entry[files_key] = files
            pout[ga] = entry
        out[platform] = pout
    return out, dict(sorted(out_infos.items()))
