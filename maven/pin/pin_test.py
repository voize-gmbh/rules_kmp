import json
import os
import tempfile
import unittest
import zipfile

import lock
import pin


def component(ga, version, *deps, constraints=()):
    group, module = ga.split(":")
    return {"id": "%s:%s" % (ga, version), "group": group, "module": module, "version": version,
            "deps": [{"selected": d, "constraint": False} for d in deps]
            + [{"selected": c, "constraint": True} for c in constraints]}


def result(*components, files=()):
    root = {"id": "root", "deps": [{"selected": c["id"], "constraint": False} for c in components]}
    return {"components": [root] + list(components),
            "artifacts": [{"component": cid, "file": path} for cid, path in files], "unresolved": []}


class VersionOrderTest(unittest.TestCase):
    def test_versions_order_like_gradle(self):
        ascending = ["1.0-dev", "1.0-alpha", "1.0-beta", "1.0-rc1", "1.0-snapshot", "1.0", "1.0.1", "1.2", "1.10",
                     "33.5.0-android", "33.5.0-jre"]
        self.assertEqual(sorted(reversed(ascending), key=lock.version_key), ascending)


class ModuleNodesTest(unittest.TestCase):
    def test_edges_skip_constraints_the_root_and_the_module_itself(self):
        nodes = lock.module_nodes(result(
            component("g:a", "1", "g:b:2", "g:a:1", constraints=["g:c:3"]),
            component("g:b", "2"),
            component("g:c", "3"),
            files=[("g:a:1", "/cache/x/a-1.jar")],
        ))
        self.assertEqual(nodes["g:a"], lock.Node("1", {"g:b"}, {"a-1.jar": "/cache/x/a-1.jar"}))
        self.assertEqual(nodes["g:c"].deps, set())


class PlatformModulesTest(unittest.TestCase):
    def test_runtime_edges_beyond_the_compile_ones_are_runtime_deps(self):
        compile_nodes = {"g:a": lock.Node("1", {"g:b"}, {"a.jar": "/a"}), "g:b": lock.Node("1", set(), {})}
        runtime_nodes = {"g:a": lock.Node("1", {"g:b", "g:c"}, {"a.jar": "/a"}),
                         "g:b": lock.Node("1", set(), {}), "g:c": lock.Node("1", set(), {})}
        a = lock.platform_modules(compile_nodes, runtime_nodes)["g:a"]
        self.assertEqual((a["deps"], a["runtime_deps"]), (["g:b"], ["g:c"]))

    def test_a_version_only_the_runtime_graph_has_gets_no_compile_edges(self):
        compile_nodes = {"g:a": lock.Node("1", {"g:b"}, {"a-1.jar": "/a1"}), "g:b": lock.Node("1", set(), {})}
        runtime_nodes = {"g:a": lock.Node("2", {"g:b"}, {"a-2.jar": "/a2"}), "g:b": lock.Node("1", set(), {})}
        a = lock.platform_modules(compile_nodes, runtime_nodes)["g:a"]
        self.assertEqual(a, {"version": "2", "deps": [], "runtime_deps": ["g:b"], "files": {"a-2.jar": "/a2"}})

    def test_qualifiers_order_below_releases(self):
        modules = lock.platform_modules({"g:a": lock.Node("1.0-rc1", set(), {})}, {"g:a": lock.Node("1.0", set(), {})})
        self.assertEqual(modules["g:a"]["version"], "1.0")


class CompileVersionsTest(unittest.TestCase):
    def test_only_a_differing_version_with_files_is_recorded(self):
        modules = {ga: {"version": "2", "deps": [], "runtime_deps": [], "files": {}} for ga in ("g:a", "g:b", "g:c")}
        lock.apply_compile_versions(modules, {
            "g:a": lock.Node("1", set(), {"a-1.jar": "/a1"}),
            "g:b": lock.Node("2", set(), {"b-2.jar": "/b2"}),
            "g:c": lock.Node("1", set(), {}),
        })
        self.assertEqual((modules["g:a"]["compile_version"], modules["g:a"]["compile_files"]), ("1", {"a-1.jar": "/a1"}))
        self.assertNotIn("compile_version", modules["g:b"])
        self.assertNotIn("compile_version", modules["g:c"])


def entry(version, *deps):
    return {"version": version, "deps": list(deps), "runtime_deps": [], "files": {}}


class KlibTest(unittest.TestCase):
    def test_manifest_dependencies_missing_from_the_metadata_are_added(self):
        modules = {"g:icons": entry("1", "g:stdlib"), "g:stdlib": entry("1"), "g:compose": entry("1", "g:stdlib")}
        manifests = {
            "g:icons": [{"unique_name": "icons", "depends": "stdlib compose"}],
            "g:stdlib": [{"unique_name": "stdlib"}],
            "g:compose": [{"unique_name": "compose", "depends": "stdlib"}],
        }
        lock.add_klib_manifest_edges(modules, manifests, lambda _: None)
        self.assertEqual(modules["g:icons"]["deps"], ["g:compose", "g:stdlib"])

    def test_the_newest_of_two_modules_with_one_unique_name_owns_it(self):
        modules = {"g:ui-old": entry("1"), "g:ui-new": entry("2"), "g:app": entry("1", "g:ui-old")}
        manifests = {
            "g:ui-old": [{"unique_name": "ui"}],
            "g:ui-new": [{"unique_name": "ui"}],
            "g:app": [{"unique_name": "app", "depends": "ui"}],
        }
        lock.add_klib_manifest_edges(modules, manifests, lambda _: None)
        self.assertEqual(modules["g:app"]["deps"], ["g:ui-new", "g:ui-old"])

    def test_frameworks_outside_the_sdk_become_link_pods(self):
        modules = {"g:sentry": entry("1")}
        manifests = {"g:sentry": [{"linkerOpts": "-framework Sentry -weak_framework UIKit -lz"}]}
        lock.add_pod_links(modules, manifests, lambda f: f == "UIKit")
        self.assertEqual(modules["g:sentry"]["link_pods"], ["Sentry"])


class GraphTest(unittest.TestCase):
    def test_cycles_lose_their_back_edge(self):
        modules = {"g:a": entry("1", "g:b"), "g:b": entry("1", "g:c"), "g:c": entry("1", "g:a")}
        lock.break_cycles(modules, lambda _: None)
        self.assertEqual([modules[m]["deps"] for m in ("g:a", "g:b", "g:c")], [["g:b"], ["g:c"], []])

    def test_overlay_modules_that_resolve_as_on_the_base_alias_it(self):
        platforms = {
            "jvm": {"g:lib": entry("1.4", "g:dep"), "g:dep": entry("1")},
            "jvm_x": {"g:lib": entry("1.4", "g:dep"), "g:dep": entry("1"), "g:own": entry("1")},
        }
        lock.alias_overlays(platforms, {"jvm_x": "jvm"})
        self.assertEqual(platforms["jvm_x"]["g:lib"], {"alias": "jvm"})
        self.assertEqual(platforms["jvm_x"]["g:dep"], {"alias": "jvm"})
        self.assertEqual(platforms["jvm_x"]["g:own"]["version"], "1")

    def test_overlay_modules_at_another_version_keep_their_entry(self):
        platforms = {
            "jvm": {"g:older": entry("1.10.0"), "g:newer": entry("1.4")},
            "jvm_x": {"g:older": entry("1.14.1"), "g:newer": entry("1.2")},
        }
        lock.alias_overlays(platforms, {"jvm_x": "jvm"})
        self.assertEqual(platforms["jvm_x"]["g:older"]["version"], "1.14.1")
        self.assertEqual(platforms["jvm_x"]["g:newer"]["version"], "1.2")

    def test_overlay_modules_with_other_dependencies_or_compile_version_keep_their_entry(self):
        compiled = dict(entry("2"), compile_version="1", compile_files={"a-1.jar": "/a1"})
        platforms = {
            "jvm": {"g:deps": entry("1", "g:x"), "g:cv": compiled},
            "jvm_x": {"g:deps": entry("1"), "g:cv": entry("2")},
        }
        lock.alias_overlays(platforms, {"jvm_x": "jvm"})
        self.assertEqual(platforms["jvm_x"]["g:deps"]["deps"], [])
        self.assertNotIn("compile_version", platforms["jvm_x"]["g:cv"])

    def test_aliased_entries_name_no_artifacts(self):
        platforms = {
            "jvm": {"g:a": dict(entry("1.1"), files={"a.jar": "/a11"})},
            "jvm_x": {"g:a": {"alias": "jvm"}, "g:b": dict(entry("1"), files={"b.jar": "/b"})},
        }
        entries, artifacts = lock.lock_entries(platforms)
        self.assertEqual(sorted(artifacts), ["g:a:1.1:a.jar", "g:b:1:b.jar"])
        self.assertEqual(entries["jvm_x"]["g:a"], {"alias": "jvm"})
        self.assertEqual(entries["jvm"]["g:a"]["files"], ["g:a:1.1:a.jar"])


def config(**overrides):
    c = {"platforms": {}, "jvm_version": 21, "repositories": [], "artifacts": [], "compile_versions": [],
         "omit_dependencies": []}
    c.update(overrides)
    return c


def artifact(coordinates, platforms, scope="compile"):
    return {"coordinates": coordinates, "platforms": platforms, "scope": scope, "excludes": [], "bom": False}


class GradleRequestTest(unittest.TestCase):
    def resolutions(self, **overrides):
        return {r["name"]: r for r in pin.gradle_request(config(**overrides))["resolutions"]}

    def coordinates(self, r):
        return [d["coordinates"] for d in r["dependencies"]]

    def test_scopes_pick_the_classpaths(self):
        rs = self.resolutions(artifacts=[
            artifact("g:both:1", ["jvm"]),
            artifact("g:provided:1", ["jvm"], "provided"),
            artifact("g:runtime:1", ["jvm"], "runtime"),
        ])
        self.assertEqual(self.coordinates(rs["jvm/compile"]), ["g:both:1", "g:provided:1"])
        self.assertEqual(self.coordinates(rs["jvm/runtime"]), ["g:both:1", "g:runtime:1"])
        self.assertEqual(rs["jvm/runtime"]["attributes"]["org.gradle.usage"], "java-runtime")

    def test_single_resolution_platforms_take_every_scope(self):
        rs = self.resolutions(artifacts=[artifact("g:a:1", ["ios_arm64", "tools"], "runtime")])
        self.assertEqual(sorted(rs), ["ios_arm64/compile", "tools/compile"])
        self.assertEqual(self.coordinates(rs["ios_arm64/compile"]), ["g:a:1"])
        self.assertEqual(rs["ios_arm64/compile"]["attributes"]["org.jetbrains.kotlin.native.target"], "ios_arm64")
        self.assertEqual(rs["tools/compile"]["attributes"]["org.gradle.usage"], "java-runtime")

    def test_overlays_resolve_like_their_base(self):
        rs = self.resolutions(platforms={"jvm_x": "jvm"}, artifacts=[artifact("g:a:1", ["jvm_x"])])
        self.assertEqual(rs["jvm_x/compile"]["attributes"], self.resolutions(
            artifacts=[artifact("g:a:1", ["jvm"])])["jvm/compile"]["attributes"])

    def test_android_resolves_release_variants(self):
        rs = self.resolutions(artifacts=[artifact("g:a:1", ["android"])])
        attrs = rs["android/compile"]["attributes"]
        self.assertEqual(attrs["com.android.build.api.attributes.BuildTypeAttr"], "release")
        self.assertEqual(attrs["org.jetbrains.kotlin.platform.type"], "androidJvm")

    def test_compile_versions_resolve_alone_with_the_compile_attributes(self):
        rs = self.resolutions(artifacts=[artifact("g:a:2", ["jvm"])],
                              compile_versions=[{"coordinates": "g:a:1", "platforms": ["jvm"]}])
        pins = rs["jvm/compile_versions"]
        self.assertEqual((self.coordinates(pins), pins["transitive"]), (["g:a:1"], False))
        self.assertEqual(pins["attributes"], rs["jvm/compile"]["attributes"])

    def test_unknown_platforms_are_rejected(self):
        with self.assertRaises(SystemExit):
            pin.gradle_request(config(artifacts=[artifact("g:a:1", ["linux_arm64"])]))


class InputsTest(unittest.TestCase):
    CONFIG = {"lock": "maven_lock.json", "platforms": {}, "jvm_version": 21, "repositories": [],
              "artifacts": [{"coordinates": "g:a:1", "platforms": ["jvm"]}], "compile_versions": [],
              "omit_dependencies": []}

    def test_a_lock_is_current_only_for_the_declarations_it_was_pinned_from(self):
        with tempfile.TemporaryDirectory() as d:
            path = pin.Path(d) / "maven_lock.json"
            self.assertFalse(pin.is_current(self.CONFIG, path))
            path.write_text(json.dumps({"inputs_sha256": pin.inputs_sha256(self.CONFIG), "artifacts": {}}))
            self.assertTrue(pin.is_current(dict(reversed(list(self.CONFIG.items()))), path))
            bumped = dict(self.CONFIG, artifacts=[{"coordinates": "g:a:2", "platforms": ["jvm"]}])
            self.assertFalse(pin.is_current(bumped, path))


class FakeRepositories(pin.Repositories):
    def __init__(self, repositories, serves):
        super().__init__(repositories)
        self.serves = serves
        self.looked_up = []

    def urls(self, group, module, version, files):
        self.looked_up += list(files)
        return {name: self.serves[name] for name in files if name in self.serves}


class ArtifactInfosTest(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.addCleanup(self.dir.cleanup)

    def artifact(self, name, content):
        path = os.path.join(self.dir.name, name)
        with open(path, "wb") as f:
            f.write(content)
        return lock.Artifact("g", "a", "1", name, path)

    def test_unchanged_artifacts_keep_their_url_and_changed_ones_are_looked_up(self):
        same, changed = self.artifact("a-1.jar", b"same"), self.artifact("a-1.aar", b"new")
        repos = FakeRepositories([{"name": "r", "url": "https://r", "groups": []}],
                                 {"a-1.aar": ("https://r/g/a/1/a-1.aar", None)})
        previous = {
            "g:a:1:a-1.jar": {"url": "https://r/g/a/1/a-1.jar", "sha256": pin.sha256(same.path), "file": "a-1.jar"},
            "g:a:1:a-1.aar": {"url": "https://r/g/a/1/a-1.aar", "sha256": "0" * 64, "file": "a-1.aar"},
        }
        infos = pin.artifact_infos({"g:a:1:a-1.jar": same, "g:a:1:a-1.aar": changed}, repos, previous)
        self.assertEqual(repos.looked_up, ["a-1.aar"])
        self.assertEqual(infos["g:a:1:a-1.jar"]["url"], "https://r/g/a/1/a-1.jar")
        self.assertEqual(infos["g:a:1:a-1.aar"]["sha256"], pin.sha256(changed.path))

    def test_a_url_of_an_undeclared_repository_is_looked_up_again(self):
        jar = self.artifact("a-1.jar", b"jar")
        repos = FakeRepositories([{"name": "new", "url": "https://new", "groups": []}],
                                 {"a-1.jar": ("https://new/g/a/1/a-1.jar", None)})
        previous = {"g:a:1:a-1.jar": {"url": "https://old/g/a/1/a-1.jar", "sha256": pin.sha256(jar.path), "file": "a-1.jar"}}
        infos = pin.artifact_infos({"g:a:1:a-1.jar": jar}, repos, previous)
        self.assertEqual(infos["g:a:1:a-1.jar"]["url"], "https://new/g/a/1/a-1.jar")


    def test_an_artifact_renamed_by_its_publication_version_keeps_its_url(self):
        jar = self.artifact("a-1-android.jar", b"jar")
        repos = FakeRepositories([{"name": "r", "url": "https://r", "groups": []}], {})
        previous = {"g:a:1-android:a-1-android.jar": {
            "url": "https://r/g/a/1-android/a-1-android.jar", "sha256": pin.sha256(jar.path), "file": "a-1-android.jar"}}
        infos = pin.artifact_infos({"g:a:1:a-1-android.jar": jar}, repos, previous)
        self.assertEqual(repos.looked_up, [])
        self.assertEqual(infos["g:a:1:a-1-android.jar"]["url"], "https://r/g/a/1-android/a-1-android.jar")


class PublicationVersionsTest(unittest.TestCase):
    def test_files_published_under_another_version_take_its_coordinates(self):
        infos = {
            "com.google.guava:guava:33.5.0-jre:guava-33.5.0-android.jar": {
                "url": "https://r/com/google/guava/guava/33.5.0-jre/../33.5.0-android/guava-33.5.0-android.jar",
                "sha256": "a", "file": "guava-33.5.0-android.jar"},
            "com.google.guava:guava:33.5.0-jre:guava-33.5.0-jre.jar": {
                "url": "https://r/com/google/guava/guava/33.5.0-jre/guava-33.5.0-jre.jar", "sha256": "j",
                "file": "guava-33.5.0-jre.jar"},
            "g:b:1:b.aar": {"url": "https://r/g/b/1/b-android-1.aar", "sha256": "b", "file": "b.aar"},
        }
        entries = {
            "android": {
                "com.google.guava:guava": {"version": "33.5.0-jre", "deps": [], "runtime_deps": [],
                                           "files": ["com.google.guava:guava:33.5.0-jre:guava-33.5.0-android.jar"]},
                "g:b": {"version": "1", "deps": [], "runtime_deps": [], "files": ["g:b:1:b.aar"]},
            },
            "jvm": {"com.google.guava:guava": {"version": "33.5.0-jre", "deps": [], "runtime_deps": [],
                                               "files": ["com.google.guava:guava:33.5.0-jre:guava-33.5.0-jre.jar"]}},
        }
        entries, infos = lock.publication_versions(entries, infos)
        self.assertEqual(entries["android"]["com.google.guava:guava"]["version"], "33.5.0-android")
        self.assertEqual(entries["android"]["com.google.guava:guava"]["files"],
                         ["com.google.guava:guava:33.5.0-android:guava-33.5.0-android.jar"])
        self.assertEqual(infos["com.google.guava:guava:33.5.0-android:guava-33.5.0-android.jar"]["url"],
                         "https://r/com/google/guava/guava/33.5.0-android/guava-33.5.0-android.jar")
        self.assertEqual(entries["jvm"]["com.google.guava:guava"]["version"], "33.5.0-jre")
        self.assertEqual(entries["android"]["g:b"]["version"], "1")
        self.assertEqual(sorted(infos), [
            "com.google.guava:guava:33.5.0-android:guava-33.5.0-android.jar",
            "com.google.guava:guava:33.5.0-jre:guava-33.5.0-jre.jar",
            "g:b:1:b.aar",
        ])


    def test_a_moved_file_that_differs_from_the_one_at_its_version_fails(self):
        infos = {
            "g:a:1-jre:a-1-android.jar": {"url": "https://r/g/a/1-jre/../1-android/a-1-android.jar", "sha256": "x",
                                          "file": "a-1-android.jar"},
            "g:a:1-android:a-1-android.jar": {"url": "https://r/g/a/1-android/a-1-android.jar", "sha256": "y",
                                              "file": "a-1-android.jar"},
        }
        with self.assertRaises(SystemExit):
            lock.publication_versions({}, infos)


class RepositoriesTest(unittest.TestCase):
    def test_group_filters_keep_the_declared_order(self):
        repos = pin.Repositories([
            {"name": "google", "url": "https://g", "groups": ["androidx.", "com.google.android."]},
            {"name": "central", "url": "https://c", "groups": []},
        ])
        self.assertEqual([r["name"] for r in repos.candidates("androidx.core")], ["google", "central"])
        self.assertEqual([r["name"] for r in repos.candidates("com.google.guava")], ["central"])

    def test_published_checksums_get_back_their_leading_zeros(self):
        class Served(pin.Repositories):
            def fetch(self, url, repo):
                return json.dumps({"variants": [{"files": [{"name": "a-1.jar", "url": "a-1.jar", "sha256": "f" * 63}]}]})

        repos = Served([{"name": "central", "url": "https://c", "groups": []}])
        self.assertEqual(repos.urls("g", "a", "1", ["a-1.jar"]), {"a-1.jar": ("https://c/g/a/1/a-1.jar", "0" + "f" * 63)})


class QuarkusTest(unittest.TestCase):
    def test_properties_unescape_and_join_continued_lines(self):
        props = lock.java_properties("# comment\na\\:b=c\\:d\nlong = x,\\\n    y\nu=\\u0041\n")
        self.assertEqual(props, {"a:b": "c:d", "long": "x,y", "u": "A"})

    def test_descriptors_name_the_deployment_and_conditional_modules(self):
        with tempfile.TemporaryDirectory() as tmp:
            ext, plain = os.path.join(tmp, "ext.jar"), os.path.join(tmp, "plain.jar")
            write_jar(ext, "deployment-artifact=io.quarkus\\:quarkus-rest-deployment\\:3.1\n"
                           "conditional-dependencies=io.quarkus\\:quarkus-rest-kotlin\\:\\:jar\\:3.1\n")
            write_jar(plain, None)
            modules = {
                "io.quarkus:quarkus-rest": {"version": "3.1", "files": {"quarkus-rest-3.1.jar": ext}},
                "g:plain": {"version": "1", "files": {"plain-1.jar": plain}},
                "g:pom": {"version": "1", "files": {}},
            }
            self.assertEqual(lock.quarkus_extensions(modules), {"io.quarkus:quarkus-rest": {
                "deployment": "io.quarkus:quarkus-rest-deployment:3.1",
                "conditional": ["io.quarkus:quarkus-rest-kotlin:3.1"],
                "condition": [],
            }})

    def test_resolution_adds_deployments_and_conditional_dependencies_the_platform_can_enable(self):
        with tempfile.TemporaryDirectory() as tmp:
            jars = {}
            for name, descriptor in {
                "rest": "deployment-artifact=q\\:rest-deployment\\:1\n"
                        "conditional-dependencies=q\\:rest-kotlin\\:\\:jar\\:1 q\\:rest-hibernate\\:\\:jar\\:1\n",
                "kotlin": "deployment-artifact=q\\:kotlin-deployment\\:1\n",
                "rest-kotlin": "deployment-artifact=q\\:rest-kotlin-deployment\\:1\ndependency-condition=q\\:kotlin\n",
                "rest-hibernate": "deployment-artifact=q\\:rest-hibernate-deployment\\:1\ndependency-condition=q\\:hibernate\n",
            }.items():
                jars[name] = os.path.join(tmp, name + ".jar")
                write_jar(jars[name], descriptor)
            requests = []

            def run_gradle(gradle, java_home, request):
                requests.append(request)
                out = {}
                for r in request["resolutions"]:
                    modules = [d["coordinates"].split(":")[1] for d in r["dependencies"]]
                    out[r["name"]] = result(*[component("q:" + m, "1") for m in modules],
                                            files=[("q:%s:1" % m, jars[m]) for m in modules if m in jars])
                return out

            original = pin.run_gradle
            pin.run_gradle = run_gradle
            try:
                platforms = pin.resolve(config(artifacts=[artifact("q:rest:1", ["jvm"]), artifact("q:kotlin:1", ["jvm"])]),
                                        "gradle", "jdk")
            finally:
                pin.run_gradle = original
            jvm = platforms["jvm"]
            self.assertEqual(sorted(jvm), ["q:kotlin", "q:kotlin-deployment", "q:rest", "q:rest-deployment",
                                           "q:rest-kotlin", "q:rest-kotlin-deployment"])
            self.assertEqual(jvm["q:rest"]["quarkus_deployment"], "q:rest-deployment")
            self.assertEqual(jvm["q:rest"]["quarkus_conditional"], ["q:rest-kotlin"])
            self.assertEqual(jvm["q:rest-kotlin"]["quarkus_condition"], ["q:kotlin"])
            probes = [r for req in requests for r in req["resolutions"] if r["name"] == "jvm/quarkus_conditional"]
            self.assertTrue(probes and all(not r["transitive"] for r in probes))


def write_jar(path, descriptor):
    with zipfile.ZipFile(path, "w") as z:
        z.writestr("a/A.class", b"")
        if descriptor is not None:
            z.writestr(lock.QUARKUS_DESCRIPTOR, descriptor)


if __name__ == "__main__":
    unittest.main()
