import os
import tempfile
import unittest

import check_versions

_VERSIONS = {
    "maven__g_a_1_a_1_jar": ("g:a", "1"),
    "maven__g_a_2_a_2_jar": ("g:a", "2"),
    "maven__g_b_1_b_1_jar": ("g:b", "1"),
}


def jar(repository, name):
    return "external/rules_kmp++maven+%s/file/%s" % (repository, name)


A1 = jar("maven__g_a_1_a_1_jar", "a-1.jar")
A2 = jar("maven__g_a_2_a_2_jar", "a-2.jar")
B1 = jar("maven__g_b_1_b_1_jar", "b-1.jar")
OWN = "bazel-out/k8-fastbuild/bin/lib/lib-abi.jar"


class MismatchesTest(unittest.TestCase):
    def test_a_lower_compile_version_is_reported(self):
        self.assertEqual(check_versions.mismatches([A1, B1], [A2, B1], _VERSIONS), [("g:a", ["1"], ["2"])])

    def test_the_same_versions_pass(self):
        self.assertEqual(check_versions.mismatches([A2, B1, OWN], [A2, B1], _VERSIONS), [])

    def test_a_compile_only_module_passes(self):
        self.assertEqual(check_versions.mismatches([A1, B1], [B1], _VERSIONS), [])

    def test_jars_of_unknown_repositories_are_skipped(self):
        self.assertEqual(check_versions.mismatches([jar("maven__other", "x.jar")], [A2], _VERSIONS), [])

    def test_a_sibling_repository_layout_path_is_read(self):
        self.assertEqual(check_versions.mismatches(["../rules_kmp++maven+maven__g_a_1_a_1_jar/file/a-1.jar"], [A2], _VERSIONS), [("g:a", ["1"], ["2"])])


class MainTest(unittest.TestCase):
    def run_main(self, compile_jars, runtime_jars):
        d = tempfile.mkdtemp()
        versions = os.path.join(d, "versions.txt")
        with open(versions, "w") as f:
            for repository, (module, version) in _VERSIONS.items():
                f.write("%s %s:%s\n" % (repository, module, version))
        out = os.path.join(d, "ok")
        argv = ["--label", "//x", "--versions", versions, "--output", out]
        argv += [a for j in compile_jars for a in ("--compile", j)]
        argv += [a for j in runtime_jars for a in ("--runtime", j)]
        return check_versions.main(argv), os.path.exists(out)

    def test_success_writes_the_output(self):
        self.assertEqual(self.run_main([A2], [A2]), (0, True))

    def test_a_mismatch_fails_without_output(self):
        self.assertEqual(self.run_main([A1], [A2]), (1, False))


if __name__ == "__main__":
    unittest.main()
