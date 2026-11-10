"""Test rules for JVM (JUnit Platform) tests."""

load("@rules_java//java/common:java_common.bzl", "java_common")
load("@rules_java//java/common:java_info.bzl", "JavaInfo")
load("//maven:platform.bzl", "MAVEN_PLATFORM_ATTRS", "maven_platform_transition")

_EXEC_JDK = "@bazel_tools//tools/jdk:bootstrap_runtime_toolchain_type"

# A test rule's own "test" exec group replaces Bazel's default one, which only admits execution
# platforms with every constraint of the target platform. rules_java registers its remote JDKs as
# bootstrap runtimes for the execution platform they run on.
TEST_ON_EXEC_PLATFORM = {"test": exec_group(toolchains = [_EXEC_JDK])}

def exec_platform_jdk(ctx):
    """The JavaRuntimeInfo of a JDK for the platform a rule using TEST_ON_EXEC_PLATFORM runs its test on."""
    return ctx.exec_groups["test"].toolchains[_EXEC_JDK].java_runtime

def test_on_exec_platform_info():
    """ExecutionInfo for a rule using TEST_ON_EXEC_PLATFORM, which keeps its test on the platform whose JDK
    it runs even with --use_target_platform_for_tests."""
    return testing.ExecutionInfo({}, exec_group = "test")

# The JVM runs in the zone TZ names, as under Gradle, and in UTC without one. Bazel sets TZ=UTC for
# tests; --test_env=TZ=<zone> moves them.
_LAUNCHER = """#!/usr/bin/env bash
set -euo pipefail
if [[ -z "${{RUNFILES_DIR:-}}" ]]; then
  if [[ -n "${{TEST_SRCDIR:-}}" ]]; then RUNFILES_DIR="$TEST_SRCDIR"; else RUNFILES_DIR="$0.runfiles"; fi
fi
RUNFILES_DIR="$(cd "$RUNFILES_DIR" && pwd)"
main="$RUNFILES_DIR/_main"
java="$main/{java}"
tmp="${{TEST_TMPDIR:-$(mktemp -d)}}"
argfile="$tmp/jvm-args"
{{
  printf -- '-cp\\n'
  sep=""
  cp=""
  for d in {resource_dirs}; do
    if [[ -d "$main/$d" ]]; then
      dir="$main/$d"
      {copy_resource_dirs}
      cp+="$sep$dir"; sep=":"
    fi
  done
  while IFS= read -r entry; do cp+="$sep$main/$entry"; sep=":"; done < "$main/{classpath_file}"
  printf '%s\\n' "$cp"
}} > "$argfile"
test_jars=""
for j in {test_jars}; do test_jars+="${{test_jars:+:}}$main/$j"; done
{preamble}cd "$main/{workdir}"
exec "$java" "-Duser.timezone=${{TZ:-UTC}}" {jvm_flags} "-Dbazel.test.jars=$test_jars" "@$argfile" {main_class} "$@"
"""

# Placeholders in jvm_flags resolved when the test starts.
_PLACEHOLDERS = {
    "{runfiles}": ("RUNFILES_DIR", None),
    "{outputs}": ("outputs", 'outputs="${TEST_UNDECLARED_OUTPUTS_DIR:-$tmp}"\n'),
    "{workspace}": ("BUILD_WORKSPACE_DIRECTORY", ': "${BUILD_WORKSPACE_DIRECTORY:?run this target with bazel run}"\n'),
}

def _quote_flag(flag, preamble):
    quoted = "'%s'" % flag.replace("'", "'\\''")
    for token, (var, setup) in _PLACEHOLDERS.items():
        if token in quoted:
            quoted = quoted.replace(token, "'\"$%s\"'" % var)
            if setup and setup not in preamble:
                preamble.append(setup)
    return quoted

def _rel(f):
    # Runfiles path relative to the main repository's runfiles root.
    return f.short_path

def _launcher(ctx, runtime):
    infos = [d[JavaInfo] for d in ctx.attr.deps + ctx.attr.runtime_deps]
    runtime_jars = depset(transitive = [i.transitive_runtime_jars for i in infos])
    test_jars = [j for t in ctx.attr.test_jars for j in t[JavaInfo].runtime_output_jars]

    classpath_file = ctx.actions.declare_file(ctx.label.name + ".classpath")
    excluded = {}
    if ctx.attr.resource_dirs:
        for t in ctx.attr.test_jars + ctx.attr.own_libs:
            if OutputGroupInfo in t and hasattr(t[OutputGroupInfo], "resources_jar"):
                for j in t[OutputGroupInfo].resources_jar.to_list():
                    excluded[j.path] = True
    classpath = [j for j in runtime_jars.to_list() if j.path not in excluded]

    # First-party jars before third-party ones, like Gradle's project-dependencies-first order, so
    # e.g. a module's logback.xml wins over one shipped inside a library.
    classpath = [j for j in classpath if not j.short_path.startswith("../")] + [j for j in classpath if j.short_path.startswith("../")]
    classpath += [j for j in ctx.files.classpath_suffix if j not in classpath]
    ctx.actions.write(classpath_file, "\n".join([j.short_path for j in classpath]) + "\n")

    jvm_flags = [
        # Gradle's Test task default; kotlinx.coroutines also enables stack trace recovery with it.
        "-ea",
        "-Dfile.encoding=UTF-8",
        "-Duser.language=en",
        "-Duser.country=US",
        "-Djava.awt.headless=true",
        "-XX:+UseParallelGC",
        "-Xmx" + ctx.attr.max_heap,
    ]
    jvm_flags += [ctx.expand_location(f, ctx.attr.data + ctx.attr.tools) for f in ctx.attr.jvm_flags]
    preamble = []
    quoted_flags = [_quote_flag(f, preamble) for f in jvm_flags]

    # Variables naming a placeholder are exported by the launcher, which knows the absolute paths.
    env = {}
    exports = []
    for k, v in ctx.attr.env.items():
        v = ctx.expand_location(v, ctx.attr.data + ctx.attr.tools)
        if any([token in v for token in _PLACEHOLDERS]):
            exports.append("export %s=%s\n" % (k, _quote_flag(v, preamble)))
        else:
            env[k] = v

    launcher = ctx.actions.declare_file(ctx.label.name)
    ctx.actions.write(launcher, _LAUNCHER.format(
        java = runtime.java_executable_runfiles_path,
        classpath_file = classpath_file.short_path,
        test_jars = " ".join([_rel(j) for j in test_jars]),
        workdir = ctx.attr.workdir or ctx.label.package,
        preamble = "".join(preamble + exports),
        jvm_flags = " ".join(quoted_flags),
        main_class = ctx.attr.main_class,
        resource_dirs = " ".join(ctx.attr.resource_dirs) or "''",
        copy_resource_dirs = 'dir="$tmp/resources/$d"; mkdir -p "$dir"; cp -RL "$main/$d/." "$dir/"' if ctx.attr.copy_resource_dirs else ":",
    ), is_executable = True)

    runfiles = ctx.runfiles(
        files = [classpath_file] + ctx.files.data + ctx.files.tools + ctx.files.classpath_suffix,
        transitive_files = depset(transitive = [runtime_jars, runtime.files]),
    )
    for d in ctx.attr.data + ctx.attr.tools:
        runfiles = runfiles.merge(d[DefaultInfo].default_runfiles)
    return [
        DefaultInfo(executable = launcher, runfiles = runfiles),
        RunEnvironmentInfo(environment = env),
    ]

def _kmp_jvm_test_impl(ctx):
    return _launcher(ctx, exec_platform_jdk(ctx)) + [test_on_exec_platform_info()]

def _target_platform_impl(ctx):
    return _launcher(ctx, ctx.attr._jdk[java_common.JavaRuntimeInfo])

_ATTRS = MAVEN_PLATFORM_ATTRS | {
    "deps": attr.label_list(providers = [JavaInfo]),
    "runtime_deps": attr.label_list(providers = [JavaInfo]),
    "test_jars": attr.label_list(providers = [JavaInfo], doc = "Libraries whose jars are scanned for tests."),
    "own_libs": attr.label_list(providers = [JavaInfo], doc = "The module's main libraries, whose resource jars resource_dirs replace."),
    "classpath_suffix": attr.label_list(
        allow_files = [".jar"],
        doc = "Jars put last on the classpath, after every dependency (AGP's mockable android.jar).",
    ),
    "data": attr.label_list(allow_files = True),
    "jvm_flags": attr.string_list(doc = """JVM flags; $(location) is expanded against data. {runfiles} becomes the
absolute runfiles root, {outputs} the undeclared test outputs directory and {workspace} the workspace
directory (bazel run only)."""),
    "env": attr.string_dict(doc = "Environment variables; $(location) and the jvm_flags placeholders work as in jvm_flags."),
    "max_heap": attr.string(default = "2g"),
    "workdir": attr.string(doc = "Working directory relative to the workspace root; defaults to the package."),
    "main_class": attr.string(default = "de.voize.bazel.testing.BazelJUnitRunner"),
    "resource_dirs": attr.string_list(doc = """Workspace-relative resource directories put first on the
classpath. Gradle runs a module's tests with its own resources as directories (not jars), and some
tests turn resource URLs into file paths."""),
    "copy_resource_dirs": attr.bool(doc = """Put copies of resource_dirs on the classpath instead of the runfiles
symlinks, for tests that inspect resource files without following links (e.g. okio's metadata)."""),
}

_TOOLS_DOC = """Programs the test starts, such as a database server, built for the platform the test runs on:
a select() in them picks that platform's binaries. $(location) in jvm_flags is expanded against them too."""

_EXEC_PLATFORM_ATTRS = dict(_ATTRS, tools = attr.label_list(allow_files = True, cfg = config.exec("test"), doc = _TOOLS_DOC))

_TARGET_PLATFORM_ATTRS = dict(
    _ATTRS,
    tools = attr.label_list(allow_files = True, doc = _TOOLS_DOC),
    _jdk = attr.label(
        default = "@bazel_tools//tools/jdk:current_java_runtime",
        providers = [java_common.JavaRuntimeInfo],
    ),
)

kmp_jvm_test = rule(
    implementation = _kmp_jvm_test_impl,
    cfg = maven_platform_transition,
    test = True,
    doc = """Runs on the first execution platform with a JDK, e.g. a remote executor of another CPU
than the target platform: bytecode and the jars of a JVM test run anywhere.""",
    attrs = _EXEC_PLATFORM_ATTRS,
    exec_groups = TEST_ON_EXEC_PLATFORM,
)

kmp_jvm_jni_test = rule(
    implementation = _target_platform_impl,
    cfg = maven_platform_transition,
    test = True,
    doc = """kmp_jvm_test for tests that load native libraries built for the target platform (Robolectric's
native runtime, layoutlib): runs on an execution platform matching the target platform.""",
    attrs = _TARGET_PLATFORM_ATTRS,
)

kmp_jvm_test_binary = rule(
    implementation = _target_platform_impl,
    cfg = maven_platform_transition,
    executable = True,
    doc = "kmp_jvm_test as a `bazel run` target, for runs that write into the workspace.",
    attrs = _TARGET_PLATFORM_ATTRS,
)

def kmp_jvm_tests(name, suites, data, jvm_flags, **kwargs):
    """A kmp_jvm_test, plus one per suite holding the test classes the main target leaves out.

    Args:
      name: Name of the main target; a suite's target swaps the trailing "_test" for "_<suite>_test".
      suites: Suite name -> {"classes": [class name prefixes], "data": [extra runtime files]}.
        Gives tests that need much more data (e.g. the whole source tree) a target of their own, so
        the main target doesn't rerun whenever any of it changes.
      data: Runtime files of every target.
      jvm_flags: JVM flags of every target.
      **kwargs: Other kmp_jvm_test attributes, the same for every target.
    """
    moved = [c for s in suites.values() for c in s["classes"]]
    kmp_jvm_test(
        name = name,
        data = data,
        jvm_flags = jvm_flags + (["-Dbazel.junit.excludeClasses=" + ",".join(moved)] if moved else []),
        **kwargs
    )
    base = name[:-len("_test")] if name.endswith("_test") else name
    for suite, s in suites.items():
        kmp_jvm_test(
            name = "%s_%s_test" % (base, suite),
            data = data + s.get("data", []),
            jvm_flags = jvm_flags + ["-Dbazel.junit.includeClasses=" + ",".join(s["classes"])],
            **kwargs
        )
