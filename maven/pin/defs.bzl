"""maven_pin: `bazel run`s the lock generator with a hub's declarations, Gradle and a JDK."""

load("@rules_java//java/common:java_common.bzl", "java_common")

def _rlocation(short_path):
    return short_path[3:] if short_path.startswith("../") else "_main/" + short_path

_SCRIPT = """#!/usr/bin/env bash
set -euo pipefail
export RUNFILES_DIR="${{RUNFILES_DIR:-$0.runfiles}}"
exec "$RUNFILES_DIR/{tool}" \\
  --config "$RUNFILES_DIR/{config}" \\
  --gradle "$RUNFILES_DIR/{gradle}" \\
  --java-home "$RUNFILES_DIR/{java_home}" \\
  "$@"
"""

def _maven_pin_impl(ctx):
    java = ctx.attr._java_runtime[java_common.JavaRuntimeInfo]
    launchers = [f for f in ctx.files.gradle if f.short_path.endswith("/bin/gradle")]
    if len(launchers) != 1:
        fail("%s holds no single bin/gradle" % ctx.attr.gradle.label)
    script = ctx.actions.declare_file(ctx.label.name + ".sh")
    ctx.actions.write(script, _SCRIPT.format(
        tool = _rlocation(ctx.executable._tool.short_path),
        config = _rlocation(ctx.file.config.short_path),
        gradle = _rlocation(launchers[0].short_path),
        java_home = _rlocation(java.java_home_runfiles_path),
    ), is_executable = True)
    runfiles = ctx.runfiles(
        files = [ctx.file.config],
        transitive_files = depset(ctx.files.gradle, transitive = [java.files]),
    ).merge(ctx.attr._tool[DefaultInfo].default_runfiles)
    return [DefaultInfo(executable = script, runfiles = runfiles)]

maven_pin = rule(
    implementation = _maven_pin_impl,
    executable = True,
    doc = "Resolves the declared artifacts and rewrites the lock in the workspace `bazel run` runs in.",
    attrs = {
        "config": attr.label(allow_single_file = [".json"], mandatory = True, doc = "The maven extension's declarations."),
        "gradle": attr.label(mandatory = True, doc = "The files of the Gradle distribution that resolves."),
        "_tool": attr.label(default = "//maven/pin", executable = True, cfg = "target"),
        "_java_runtime": attr.label(
            default = "@bazel_tools//tools/jdk:current_java_runtime",
            providers = [java_common.JavaRuntimeInfo],
        ),
    },
)
