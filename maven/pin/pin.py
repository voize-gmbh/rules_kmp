"""Resolves a workspace's declared Maven artifacts with Gradle and writes the lock.

Run through `bazel run @maven//:pin`, which passes the declarations of the maven extension's tags.
"""

import argparse
import base64
import concurrent.futures
import hashlib
import json
import netrc
import os
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

import lock

NATIVE_PLATFORMS = ("ios_arm64", "ios_simulator_arm64", "ios_x64", "macos_arm64", "macos_x64")
BUILTIN_PLATFORMS = ("jvm", "android", "tools", "js", "wasm_js") + NATIVE_PLATFORMS

USAGE = "org.gradle.usage"


def resolutions(platform, kind, jvm_version):
    """The consumer attributes of a platform's resolutions: role -> attributes.

    compile and runtime match what the Kotlin and Android Gradle plugins resolve a compilation's
    classpaths with. Kotlin/Native and tools have one resolution only, recorded as compile.
    """
    library = {"org.gradle.category": "library"}
    jvm = library | {
        "org.gradle.jvm.environment": "standard-jvm",
        "org.gradle.jvm.version": jvm_version,
        "org.jetbrains.kotlin.platform.type": "jvm",
    }
    if kind == "jvm":
        return {"compile": jvm | {USAGE: "java-api"}, "runtime": jvm | {USAGE: "java-runtime"}}
    if kind == "tools":
        return {"compile": jvm | {USAGE: "java-runtime"}}
    if kind == "android":
        android = jvm | {
            "org.gradle.jvm.environment": "android",
            "org.jetbrains.kotlin.platform.type": "androidJvm",
            # A library has one artifact for every app variant: the release one, which ships.
            "com.android.build.api.attributes.BuildTypeAttr": "release",
        }
        return {"compile": android | {USAGE: "java-api"}, "runtime": android | {USAGE: "java-runtime"}}
    if kind in NATIVE_PLATFORMS:
        return {"compile": library | {
            USAGE: "kotlin-api",
            "org.jetbrains.kotlin.platform.type": "native",
            "org.jetbrains.kotlin.native.target": kind,
        }}
    if kind == "js":
        web = library | {"org.jetbrains.kotlin.platform.type": "js", "org.jetbrains.kotlin.js.compiler": "ir"}
    elif kind == "wasm_js":
        web = library | {"org.jetbrains.kotlin.platform.type": "wasm", "org.jetbrains.kotlin.wasm.target": "js"}
    else:
        raise SystemExit("unknown platform kind %s of %s" % (kind, platform))
    return {"compile": web | {USAGE: "kotlin-api"}, "runtime": web | {USAGE: "kotlin-runtime"}}


# Which declarations each resolution gets, by scope.
_ROLE_SCOPES = {"compile": ("compile", "provided"), "runtime": ("compile", "runtime")}


def gradle_request(config):
    """The resolutions to run: per platform compile/runtime, and the pinned compile versions."""
    kinds = platform_kinds(config)
    reqs = []
    for platform in sorted(kinds):
        roles = resolutions(platform, kinds[platform], config["jvm_version"])
        single = len(roles) == 1
        for role, attrs in sorted(roles.items()):
            deps = [
                {"coordinates": a["coordinates"], "excludes": a["excludes"], "bom": a["bom"]}
                for a in config["artifacts"]
                if platform in a["platforms"] and (single or a["scope"] in _ROLE_SCOPES[role])
            ]
            reqs.append({"name": "%s/%s" % (platform, role), "attributes": attrs, "dependencies": deps,
                         "transitive": True})
        pins = [{"coordinates": c["coordinates"], "excludes": [], "bom": False}
                for c in config["compile_versions"] if platform in c["platforms"]]
        if pins:
            reqs.append({"name": "%s/compile_versions" % platform, "attributes": roles["compile"],
                         "dependencies": pins, "transitive": False})
    return {"repositories": config["repositories"], "omitDependencies": config["omit_dependencies"],
            "resolutions": reqs}


def platform_kinds(config):
    """platform -> its built-in kind, for every platform an artifact is declared for."""
    kinds = {}
    for a in config["artifacts"]:
        for p in a["platforms"]:
            kind = config["platforms"].get(p, p)
            if kind not in BUILTIN_PLATFORMS:
                raise SystemExit("%s is declared for platform %s, which is neither built in (%s) nor in "
                                 "maven.lock(platforms)" % (a["coordinates"], p, ", ".join(BUILTIN_PLATFORMS)))
            kinds[p] = kind
    return kinds


def credentials(url):
    """(login, password) for a URL's host from ~/.netrc, or None."""
    try:
        auth = netrc.netrc().authenticators(urllib.parse.urlparse(url).hostname)
    except (FileNotFoundError, netrc.NetrcParseError):
        return None
    return (auth[0], auth[2]) if auth else None


def run_gradle(gradle, java_home, request):
    with tempfile.TemporaryDirectory(prefix="maven-pin-") as tmp:
        tmp = Path(tmp)
        (tmp / "settings.gradle").write_text('rootProject.name = "maven-pin"\n')
        shutil.copy(Path(__file__).parent / "resolve.gradle", tmp / "build.gradle")
        (tmp / "gradle.properties").write_text("org.gradle.jvmargs=-Xmx4g\n")
        (tmp / "request.json").write_text(json.dumps(request))
        env = dict(os.environ, JAVA_HOME=java_home)
        for i, r in enumerate(request["repositories"]):
            auth = credentials(r["url"])
            if auth:
                env["PIN_REPOSITORY_%d_USERNAME" % i], env["PIN_REPOSITORY_%d_PASSWORD" % i] = auth
        subprocess.run(
            [gradle, "--project-dir", str(tmp), "--no-daemon", "--quiet", "--console=plain",
             "-Prequest=" + str(tmp / "request.json"), "-Presult=" + str(tmp / "result.json"), "resolve"],
            env=env, check=True,
        )
        return json.loads((tmp / "result.json").read_text())


def sdk_frameworks(target):
    """Whether a framework is in the Apple SDK of a Kotlin/Native target."""
    sdk = "macosx" if target.startswith("macos") else (
        "iphonesimulator" if "simulator" in target or target == "ios_x64" else "iphoneos")
    cache = {}

    def in_sdk(framework):
        if "path" not in cache:
            cache["path"] = Path(subprocess.run(["xcrun", "--sdk", sdk, "--show-sdk-path"], capture_output=True,
                                                text=True, check=True).stdout.strip())
        return (cache["path"] / "System/Library/Frameworks" / (framework + ".framework")).exists()

    return in_sdk


def log(message):
    print(message, file=sys.stderr)


def build_platforms(config, results):
    """platform -> group:module -> lock entry (files as name -> path)."""
    platforms = {}
    for platform, kind in sorted(platform_kinds(config).items()):
        compile_nodes = lock.module_nodes(results["%s/compile" % platform])
        runtime = results.get("%s/runtime" % platform)
        modules = lock.platform_modules(compile_nodes, lock.module_nodes(runtime) if runtime else {})
        pins = results.get("%s/compile_versions" % platform)
        if pins:
            lock.apply_compile_versions(modules, lock.module_nodes(pins))
        if kind in NATIVE_PLATFORMS:
            manifests = {
                ga: [lock.klib_manifest(path) for name, path in sorted(e["files"].items()) if name.endswith(".klib")]
                for ga, e in modules.items()
            }
            manifests = {ga: ms for ga, ms in manifests.items() if ms}
            lock.add_klib_manifest_edges(modules, manifests, log)
            lock.add_pod_links(modules, manifests, sdk_frameworks(kind))
        lock.break_cycles(modules, log)
        platforms[platform] = modules
    return platforms


class Repositories:
    """Finds the repository URL of artifacts: the first declared repository that serves them."""

    def __init__(self, repositories):
        self.repositories = repositories
        self.auth = {r["url"]: credentials(r["url"]) for r in repositories}

    def candidates(self, group):
        return [r for r in self.repositories if not r["groups"] or group.startswith(tuple(r["groups"]))]

    def _request(self, url, repo, method):
        req = urllib.request.Request(url, method=method)
        auth = self.auth.get(repo["url"])
        if auth:
            token = base64.b64encode(("%s:%s" % auth).encode()).decode()
            req.add_header("Authorization", "Basic " + token)
        return req

    def _open(self, url, repo, method):
        """The response body (b"" for HEAD), or None if the repository does not have the file.

        Network failures and server errors are retried, so neither passes for a missing file.
        """
        for attempt in range(4):
            try:
                with urllib.request.urlopen(self._request(url, repo, method), timeout=60) as resp:
                    return resp.read()
            except urllib.error.HTTPError as e:
                if e.code == 429:
                    raise RuntimeError("%s: 429 Too Many Requests, retry after %s s" % (url, e.headers.get("Retry-After")))
                if e.code < 500:
                    return None
                if attempt == 3:
                    raise
            except OSError:
                if attempt == 3:
                    raise
            time.sleep(2 ** attempt)

    def fetch(self, url, repo):
        return self._open(url, repo, "GET")

    def probe(self, url, repo):
        return self._open(url, repo, "HEAD") is not None

    def urls(self, group, module, version, files):
        """file name in the Gradle cache -> (URL, sha256 from the module metadata or None).

        Gradle caches files under the name from the module metadata, which can differ from the file
        name in the repository (e.g. animation.aar for animation-android-1.12.1.aar), so the
        published .module file maps one to the other.
        """
        base_path = "%s/%s/%s" % (group.replace(".", "/"), module, version)
        results = {}
        for repo in self.candidates(group):
            base = repo["url"].rstrip("/")
            meta = self.fetch("%s/%s/%s-%s.module" % (base, base_path, module, version), repo)
            names = {}
            if meta:
                try:
                    for variant in json.loads(meta).get("variants", []):
                        for f in variant.get("files", []):
                            names[f["name"]] = (f["url"], f.get("sha256"))
                except ValueError:
                    names = {}
            elif not self.probe("%s/%s/%s-%s.pom" % (base, base_path, module, version), repo):
                continue
            for name in files:
                url_name, sha = names.get(name, (name, None))
                url = "%s/%s/%s" % (base, base_path, url_name)
                if sha or self.probe(url, repo):
                    results[name] = (url, sha)
            if len(results) == len(files):
                break
        return results


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def artifact_infos(artifacts, repositories, previous):
    """Resolves every artifact's URL and sha256: file id -> {"url", "sha256", "file"}.

    Args:
      artifacts: file id -> lock.Artifact.
      repositories: The Repositories to look the artifacts up in.
      previous: The artifacts of the lock being replaced. One with the same file id and sha256
        keeps its URL; repositories limit how often a file may be fetched, even with HEAD.
    """
    components = {}
    for fid, a in artifacts.items():
        components.setdefault((a.group, a.module, a.version), {})[a.name] = (fid, a.path)
    infos = {}
    problems = []

    def work(comp):
        group, module, version = comp
        files = components[comp]
        digests = {name: sha256(path) for name, (_, path) in files.items()}
        urls = {}
        for name, (fid, _) in files.items():
            old = previous.get(fid)
            if old and old["sha256"] == digests[name] and any(c["url"] in old["url"] for c in repositories.candidates(group)):
                urls[name] = (old["url"], None)
        if len(urls) < len(files):
            urls.update(repositories.urls(group, module, version, [n for n in files if n not in urls]))
        out = {}
        for name, (fid, path) in files.items():
            digest = digests[name]
            if name not in urls:
                problems.append("no repository serves %s" % fid)
                continue
            url, published = urls[name]
            if published and published != digest:
                problems.append("sha256 mismatch for %s: %s published, %s in the Gradle cache" % (fid, published, digest))
            out[fid] = {"url": url, "sha256": digest, "file": name}
        return out

    with concurrent.futures.ThreadPoolExecutor(max_workers=48) as ex:
        for out in ex.map(work, sorted(components)):
            infos.update(out)
    if problems:
        for p in sorted(problems)[:50]:
            log("  " + p)
        raise SystemExit("%d artifacts have no usable repository URL; are the credentials in ~/.netrc valid?" % len(problems))
    return dict(sorted(infos.items()))


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", required=True, help="The declarations of the maven extension (JSON).")
    parser.add_argument("--gradle", required=True, help="The gradle launcher of the pinned distribution.")
    parser.add_argument("--java-home", required=True, help="The JDK that runs Gradle.")
    parser.add_argument("--workspace", default=os.environ.get("BUILD_WORKSPACE_DIRECTORY"),
                        help="The workspace whose lock to write (default: the one bazel run runs in).")
    args = parser.parse_args(argv)
    if not args.workspace:
        raise SystemExit("run me with bazel run, or pass --workspace")
    config = json.loads(Path(args.config).read_text())

    request = gradle_request(config)
    log("Resolving %d configurations with Gradle" % len(request["resolutions"]))
    results = run_gradle(os.path.abspath(args.gradle), os.path.abspath(args.java_home), request)
    problems = ["%s: %s" % (name, u) for name, r in sorted(results.items()) for u in r["unresolved"]]
    if problems:
        for p in problems:
            log(p)
        raise SystemExit("Gradle could not resolve %d dependencies" % len(problems))

    platforms = build_platforms(config, results)
    lock.alias_overlays(platforms, config["platforms"])
    entries, artifacts = lock.lock_entries(platforms)
    lock_path = Path(args.workspace) / config["lock"]
    previous = json.loads(lock_path.read_text())["artifacts"] if lock_path.exists() else {}
    log("Finding the repository of %d artifacts" % len(artifacts))
    out = {
        "version": lock.LOCK_VERSION,
        "artifacts": artifact_infos(artifacts, Repositories(config["repositories"]), previous),
        "platforms": entries,
    }
    lock_path.write_text(json.dumps(out, indent=1, sort_keys=True) + "\n")
    log("Wrote %s: %d artifacts, %s" % (lock_path, len(out["artifacts"]),
                                        {p: len(m) for p, m in sorted(out["platforms"].items())}))


if __name__ == "__main__":
    main()
