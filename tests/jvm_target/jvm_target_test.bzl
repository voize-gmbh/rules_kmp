"""Builds targets with a Kotlin toolchain whose jvm_target is 17 instead of the default."""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")

_JVM_17 = str(Label(":jvm_17"))

def _jvm_17_transition_impl(settings, _attr):
    return {"//command_line_option:extra_toolchains": [_JVM_17] + settings["//command_line_option:extra_toolchains"]}

_jvm_17_transition = transition(
    implementation = _jvm_17_transition_impl,
    inputs = ["//command_line_option:extra_toolchains"],
    outputs = ["//command_line_option:extra_toolchains"],
)

def _with_jvm_17_impl(ctx):
    return [DefaultInfo(
        files = depset(transitive = [t[DefaultInfo].files for t in ctx.attr.srcs]),
        runfiles = ctx.runfiles().merge_all([t[DefaultInfo].default_runfiles for t in ctx.attr.srcs]),
    )]

with_jvm_17 = rule(
    implementation = _with_jvm_17_impl,
    doc = "The files and runfiles of `srcs`, built with the jvm_target 17 toolchain.",
    attrs = {"srcs": attr.label_list(cfg = _jvm_17_transition)},
)

def _ksp_jvm_target_test_impl(ctx):
    env = analysistest.begin(ctx)
    ksp = [a for a in analysistest.target_actions(env) if a.mnemonic == "KotlinKsp"]
    asserts.equals(env, 1, len(ksp))
    flags = [a for a in ksp[0].argv if a.startswith("-jvm-target")]
    asserts.equals(env, ["-jvm-target=17"], flags)
    return analysistest.end(env)

ksp_jvm_target_test = analysistest.make(
    _ksp_jvm_target_test_impl,
    doc = "KSP analyses a JVM compilation for the toolchain's jvm_target.",
    config_settings = {"//command_line_option:extra_toolchains": [_JVM_17]},
)
