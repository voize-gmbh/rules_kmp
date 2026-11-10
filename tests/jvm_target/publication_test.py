"""Checks a Kotlin/JVM publication built with a jvm_target 17 toolchain: its Gradle module metadata
and the class files of its jar, compiled from Kotlin and from Java."""

import json
import os
import sys
import unittest
import zipfile

JAVA_17_CLASS_VERSION = 61


class PublicationTest(unittest.TestCase):
    def setUp(self):
        manifest = next(p for p in ARGS if p.endswith(".manifest"))
        repository = next(p for p in ARGS if not p.endswith(".manifest"))
        self.files = {}
        with open(manifest) as f:
            next(f)
            for line in f:
                path, source = line.rstrip("\n").split("\t")
                self.files[path] = os.path.join(repository, path) if source.startswith("@") else source

    def file(self, suffix):
        return next(p for name, p in self.files.items() if name.endswith(suffix))

    def test_module_says_java_17(self):
        with open(self.file("lib-1.0.0.module")) as f:
            module = json.load(f)
        versions = {
            v["name"]: v["attributes"].get("org.gradle.jvm.version")
            for v in module["variants"]
            if v["name"] in ("apiElements", "runtimeElements")
        }
        self.assertEqual({"apiElements": 17, "runtimeElements": 17}, versions)

    def test_classes_target_java_17(self):
        with zipfile.ZipFile(self.file("lib-1.0.0.jar")) as jar:
            versions = {
                name: int.from_bytes(jar.read(name)[6:8], "big")
                for name in jar.namelist()
                if name.endswith(".class")
            }
        self.assertEqual(
            {
                "rules_kmp/tests/jvm_target/Lib.class": JAVA_17_CLASS_VERSION,
                "rules_kmp/tests/jvm_target/Helper.class": JAVA_17_CLASS_VERSION,
            },
            versions,
        )


if __name__ == "__main__":
    ARGS = sys.argv[1:]
    unittest.main(argv=sys.argv[:1])
