"""Fails when a JVM compilation sees a Maven module at another version than it runs with.

Usage: check_versions.py @<params>, the params one per line:
  --label <target> --versions <versions.txt> --output <file written on success>
  --compile <jar> ... (the compile classpath) --runtime <jar> ... (the runtime classpath)

versions.txt maps each artifact's repository (maven__<file id>) to its group:module:version.
Jars that come from no such repository, such as the target's own dependencies' jars, are skipped.
"""

import argparse
import re
import sys

_REPOSITORY = re.compile(r"(?:^|[/+])(maven__[^/]+)/")


def read_versions(path):
    out = {}
    with open(path) as f:
        for line in f:
            if line.strip():
                repository, coordinates = line.split()
                out[repository] = coordinates.rpartition(":")[::2]
    return out


def module_versions(jars, versions):
    """group:module -> versions of it among `jars`."""
    out = {}
    for jar in jars:
        m = _REPOSITORY.search(jar)
        if m and m.group(1) in versions:
            module, version = versions[m.group(1)]
            out.setdefault(module, set()).add(version)
    return out


def mismatches(compile_jars, runtime_jars, versions):
    """(module, compile versions, runtime versions) of modules compiled at a version they don't run with."""
    compiled = module_versions(compile_jars, versions)
    run = module_versions(runtime_jars, versions)
    return [
        (module, sorted(compiled[module]), sorted(run[module]))
        for module in sorted(compiled)
        if module in run and not compiled[module] <= run[module]
    ]


def main(argv):
    parser = argparse.ArgumentParser(fromfile_prefix_chars="@")
    parser.add_argument("--label", required=True)
    parser.add_argument("--versions", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--compile", action="append", default=[])
    parser.add_argument("--runtime", action="append", default=[])
    args = parser.parse_args(argv)
    found = mismatches(args.compile, args.runtime, read_versions(args.versions))
    if found:
        print("%s compiles against other versions of Maven modules than it runs with:" % args.label, file=sys.stderr)
        for module, compiled, run in found:
            print("  %s: compiles against %s, runs with %s" % (module, ", ".join(compiled), ", ".join(run)), file=sys.stderr)
        print("Only targets with maven_compile_versions = True may compile against maven.compile_version.", file=sys.stderr)
        return 1
    open(args.output, "w").close()
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
