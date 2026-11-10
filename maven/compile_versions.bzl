"""The version of a Maven module a JVM compilation sees when maven.compile_version gives it two.

The hub's targets carry the lower compile version, as Gradle compiles against it. Compilations with
`maven_compile_versions = True` keep it; the others get the version the platform runs with.
"""

load("@rules_java//java/common:java_info.bzl", "JavaInfo")

MavenRuntimeJarsInfo = provider(
    doc = "The compile_version jars of the Maven modules a target compiles against.",
    fields = {"jars": "depset[struct(compile_jar, runtime_jar)]: each with the jar the platform runs with."},
)

# What puts a target on a dependent's compile classpath. `lib` is kmp_jvm_rewrap's.
_EDGES = ["deps", "exports", "lib"]

def _targets(value):
    if type(value) == "list":
        return value
    if type(value) == "dict":
        return value.keys()
    return [] if value == None else [value]

def _runtime_jars_aspect_impl(target, ctx):
    own = []
    if ctx.rule.kind == "maven_jar" and ctx.rule.files.compile_jars:
        own = [
            struct(compile_jar = c, runtime_jar = r)
            for c, r in zip(ctx.rule.files.compile_jars, ctx.rule.files.jars)
        ]
    transitive = [
        d[MavenRuntimeJarsInfo].jars
        for edge in _EDGES
        for d in _targets(getattr(ctx.rule.attr, edge, None))
        if type(d) == "Target" and MavenRuntimeJarsInfo in d
    ]
    return [MavenRuntimeJarsInfo(jars = depset(own, transitive = transitive))]

maven_runtime_jars_aspect = aspect(
    implementation = _runtime_jars_aspect_impl,
    attr_aspects = _EDGES,
    required_providers = [JavaInfo],
    provides = [MavenRuntimeJarsInfo],
)

def runtime_jars(targets):
    """The MavenRuntimeJarsInfo.jars of targets the aspect was applied to."""
    return [t[MavenRuntimeJarsInfo].jars for t in targets if MavenRuntimeJarsInfo in t]

def with_runtime_versions(classpath, jars):
    """`classpath` (a depset) with each compile_version jar in `jars` replaced by its runtime jar."""
    pairs = depset(transitive = jars).to_list()
    if not pairs:
        return classpath
    runtime = {p.compile_jar: p.runtime_jar for p in pairs}
    return depset([runtime.get(f, f) for f in classpath.to_list()], order = "preorder")

def check_versions(ctx, compile_classpath, runtime_classpath):
    """Declares the validation action that compares the two classpaths' Maven versions.

    Returns its output, for the `_validation` output group.
    """
    out = ctx.actions.declare_file(ctx.label.name + "_maven_versions.ok")
    args = ctx.actions.args()
    args.set_param_file_format("multiline")
    args.use_param_file("@%s", use_always = True)
    label = str(ctx.label)
    # One argument: argparse reads a separate "@repo//..." value as a file of arguments.
    args.add("--label=" + (label[2:] if label.startswith("@@//") else label))
    args.add("--versions", ctx.file._maven_versions)
    args.add("--output", out)
    args.add_all(compile_classpath, before_each = "--compile")
    args.add_all(runtime_classpath, before_each = "--runtime")
    ctx.actions.run(
        executable = ctx.executable._check_versions,
        arguments = [args],
        inputs = [ctx.file._maven_versions],
        outputs = [out],
        mnemonic = "MavenVersionCheck",
        progress_message = "Checking the Maven versions %{label} compiles against",
    )
    return out

VERSION_CHECK_ATTRS = {
    "_maven_versions": attr.label(
        default = "@kmp_maven_libs//:versions.txt",
        allow_single_file = True,
    ),
    "_check_versions": attr.label(
        default = "//maven:check_versions",
        executable = True,
        cfg = "exec",
    ),
}
