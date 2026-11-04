"""Builds the lock that @rules_kmp//maven:extension.bzl reads from resolved Gradle graphs.

Each platform has a compile and a runtime resolution (only one for Kotlin/Native and tools). A
module gets the highest version either resolved; its deps are the edges of the compile graph, its
runtime_deps the further edges of the runtime graph.
"""

import collections
import functools
import os
import re
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


def compatible(a, b, group=""):
    """Same major version (same minor for 0.x and Kotlin), i.e. one build may stand in for the other."""
    pa, pb = re.split(r"[.\-]", a), re.split(r"[.\-]", b)
    n = 2 if pa[0] == "0" or group == "org.jetbrains.kotlin" else 1
    return pa[:n] == pb[:n]


def alias_overlays(platforms, overlays):
    """Points an overlay platform's modules at its base platform where their versions are compatible.

    Args:
      platforms: platform -> group:module -> entry.
      overlays: overlay platform -> its base platform.
    """
    for overlay, base_name in sorted(overlays.items()):
        base = platforms.get(base_name, {})
        modules = platforms.get(overlay, {})
        for ga, entry in sorted(modules.items()):
            b = base.get(ga)
            if b and compatible(b["version"], entry["version"], ga.split(":")[0]):
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
            pout[ga] = e
        out[platform] = pout
    return out, artifacts
