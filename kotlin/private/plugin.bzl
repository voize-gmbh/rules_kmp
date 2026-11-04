"""Kotlin compiler plugins."""

load("//kotlin:providers.bzl", "KtCompilerPluginInfo")

def _kmp_compiler_plugin_impl(ctx):
    return [KtCompilerPluginInfo(
        id = ctx.attr.id,
        jvm_jars = ctx.files.jvm_jars,
        native_jars = ctx.files.native_jars,
        options = ctx.attr.options,
    )]

kmp_compiler_plugin = rule(
    implementation = _kmp_compiler_plugin_impl,
    attrs = {
        "id": attr.string(mandatory = True),
        "jvm_jars": attr.label_list(allow_files = [".jar"], cfg = "exec"),
        "native_jars": attr.label_list(allow_files = [".jar"], cfg = "exec"),
        "options": attr.string_list(),
    },
    provides = [KtCompilerPluginInfo],
)
