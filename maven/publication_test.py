"""Tests for publication.py: the POMs and Gradle module metadata of a repository."""

import json
import os
import tempfile
import unittest
import xml.etree.ElementTree as ET

import publication

NS = "{http://maven.apache.org/POM/4.0.0}"


def dep(group, module, version=None, pom_artifact=None):
    return {
        "group": group,
        "module": module,
        "version": version,
        "pom": {"group": group, "artifact": pom_artifact or module, "version": version},
    }


def file(kind, short_path, classifier=None, extension="jar"):
    return {
        "kind": kind,
        "classifier": classifier,
        "extension": extension,
        "short_path": short_path,
        "size": 1,
        "sha512": "a",
        "sha256": "b",
        "sha1": "c",
        "md5": "d",
    }


SPEC = {
    "group": "g",
    "artifact": "lib",
    "kind": "kmp",
    "jvm_version": 21,
    "pom": {},
    "publications": [
        {
            "role": "target",
            "artifact": "lib-jvm",
            "gradle_name": "jvm",
            "target_kind": "jvm",
            "native_target": None,
            "files": [file("main", "lib/jvm.jar"), file("sources", "lib/jvm-sources.jar", "sources")],
            "api": [dep("g", "base")],
            "implementation": [dep("org.x", "coroutines", "1.0", "coroutines-jvm")],
            "runtime_only": [],
        },
        {
            "role": "target",
            "artifact": "lib-iosarm64",
            "gradle_name": "iosArm64",
            "target_kind": "native",
            "native_target": "ios_arm64",
            "files": [
                file("main", "lib/ios.klib", extension="klib"),
                file("cinterop", "lib/pod.klib", "cinterop-Pod", "klib"),
                file("sources", "lib/ios-sources.jar", "sources"),
            ],
            "api": [dep("g", "base")],
            "implementation": [dep("org.x", "coroutines", "1.0", "coroutines-iosarm64")],
            "runtime_only": [],
        },
        {
            "role": "root",
            "artifact": "lib",
            "files": [file("sources", "lib/sources.jar", "sources")],
            "api": [],
            "implementation": [dep("org.x", "coroutines", "1.0", "coroutines-jvm")],
            "runtime_only": [],
        },
    ],
}


class RepositoryTest(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp()
        spec = os.path.join(self.dir, "spec.json")
        with open(spec, "w") as f:
            json.dump(SPEC, f)
        self.out = os.path.join(self.dir, "repo")
        self.manifest = os.path.join(self.dir, "manifest")
        publication.main(
            ["repository", "--spec", spec, "--version", "1.2.3", "--out", self.out, "--manifest", self.manifest]
        )

    def module(self, artifact):
        with open(os.path.join(self.out, "g/%s/1.2.3/%s-1.2.3.module" % (artifact, artifact))) as f:
            return {v["name"]: v for v in json.load(f)["variants"]}

    def pom_deps(self, artifact):
        root = ET.parse(os.path.join(self.out, "g/%s/1.2.3/%s-1.2.3.pom" % (artifact, artifact))).getroot()
        return [
            (d.findtext(NS + "artifactId"), d.findtext(NS + "version"), d.findtext(NS + "scope"))
            for d in root.iter(NS + "dependency")
        ]

    def test_jvm_api_variant_has_only_api_dependencies(self):
        variants = self.module("lib-jvm")
        self.assertEqual([d["module"] for d in variants["jvmApiElements-published"]["dependencies"]], ["base"])
        self.assertEqual(
            [d["module"] for d in variants["jvmRuntimeElements-published"]["dependencies"]], ["base", "coroutines"]
        )

    def test_native_api_variant_has_every_dependency_and_the_cinterop_klibs(self):
        api = self.module("lib-iosarm64")["iosArm64ApiElements-published"]
        self.assertEqual([d["module"] for d in api["dependencies"]], ["base", "coroutines"])
        self.assertEqual(
            [f["url"] for f in api["files"]], ["lib-iosarm64-1.2.3.klib", "lib-iosarm64-1.2.3-cinterop-Pod.klib"]
        )

    def test_root_points_at_the_target_modules(self):
        root = self.module("lib")
        self.assertEqual(
            root["jvmRuntimeElements-published"]["available-at"]["url"], "../../lib-jvm/1.2.3/lib-jvm-1.2.3.module"
        )
        self.assertNotIn("metadataApiElements", root)

    def test_poms_name_the_target_modules_of_dependencies_and_their_scopes(self):
        self.assertEqual(self.pom_deps("lib-jvm"), [("base", "1.2.3", "compile"), ("coroutines-jvm", "1.0", "runtime")])
        self.assertEqual(
            self.pom_deps("lib-iosarm64"), [("base", "1.2.3", "compile"), ("coroutines-iosarm64", "1.0", "compile")]
        )
        self.assertEqual(self.pom_deps("lib"), [("coroutines", "1.0", "runtime")])

    def test_manifest_lists_built_and_written_files(self):
        with open(self.manifest) as f:
            lines = f.read().splitlines()
        self.assertEqual(lines[0], "version\t1.2.3")
        self.assertIn("g/lib-iosarm64/1.2.3/lib-iosarm64-1.2.3-cinterop-Pod.klib\tlib/pod.klib", lines)
        self.assertIn("g/lib/1.2.3/lib-1.2.3.module\t@g/lib/1.2.3/lib-1.2.3.module", lines)


if __name__ == "__main__":
    unittest.main()
