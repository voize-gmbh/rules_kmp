"""Checks that additions a compilation never names leave its filtered classpath unchanged.

Arguments: the filtered classpath directories of User.kt against library versions v1 and v2, and of
Plain.kt against v1 and v3 (see BUILD.bazel).
"""
import pathlib
import sys
import zipfile


def jars(directory):
    return {p.name: p.read_bytes() for p in sorted(pathlib.Path(directory).glob("*.jar"))}


def facade(directory):
    for path in sorted(pathlib.Path(directory).glob("*.jar")):
        with zipfile.ZipFile(path) as z:
            names = z.namelist()
            if "fixture/lib/HelperKt.class" in names:
                return z.read("fixture/lib/HelperKt.class"), names
    raise AssertionError(f"no filtered HelperKt in {directory}")


def same(a, b):
    x, y = jars(a), jars(b)
    assert x, f"no filtered jars in {a}"
    assert x.keys() == y.keys(), (sorted(x), sorted(y))
    for name in x:
        assert x[name] == y[name], f"{name} differs between {a} and {b}"


def main():
    user_v1, user_v2, plain_v1, plain_v3 = sys.argv[1:5]
    same(user_v1, user_v2)
    same(plain_v1, plain_v3)

    user, _ = facade(user_v1)
    for kept in (b"named", b"plus", b"getValue", b"inlined", b"helperForInline", b"getNamedProperty"):
        assert kept in user, f"{kept} was filtered out for User.kt"
    plain, plain_names = facade(plain_v3)
    assert b"neverNamed" not in plain and b"twice" not in plain
    assert b"SourceDebugExtension" not in plain and b"SMAP" not in plain, "source map kept without inline functions"
    assert not any(n.startswith("fixture/lib/HelperKt$") for n in plain_names), plain_names
    return 0


if __name__ == "__main__":
    sys.exit(main())
