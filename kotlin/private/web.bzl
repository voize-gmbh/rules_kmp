"""Kotlin/JS and Kotlin/Wasm test executables, run with Node.js."""

load("//kotlin:providers.bzl", "KlibInfo")
load(":toolchain.bzl", "WEB_TOOLCHAIN_TYPE", "kotlin_toolchain_info")

_RUNNER = """#!/usr/bin/env bash
set -euo pipefail
# As for JVM tests: cached results must not depend on the host's time zone or locale.
export TZ=UTC LANG=en_US.UTF-8
main="${{RUNFILES_DIR:-${{TEST_SRCDIR:-$0.runfiles}}}}/_main"
# Node resolves npm imports next to the bundle, so lay the bundle out with a node_modules dir.
run="${{TEST_TMPDIR:-$(mktemp -d)}}/bundle"
mkdir -p "$run/node_modules"
for f in "$main/{dir}"/*; do ln -sf "$f" "$run/"; done
{npm_links}
cd "$run"
exec "$main/{node}" --preserve-symlinks --preserve-symlinks-main {node_flags} "$main/{harness}" "$run/{entry}" "$@"
"""

def _kmp_web_test_impl(ctx):
    tc = kotlin_toolchain_info(ctx, WEB_TOOLCHAIN_TYPE)
    target = ctx.attr.target
    test = ctx.attr.test_klib[KlibInfo]
    stdlib = tc.web_stdlibs[target]
    kotlin_test = tc.web_test_libs[target]
    libraries = depset(transitive = [test.transitive_klibs, stdlib.transitive_klibs, kotlin_test.transitive_klibs], order = "postorder").to_list()
    include = test.klibs[0]
    libraries = [l for l in libraries if l != include]
    out_dir = ctx.actions.declare_directory(ctx.label.name + "_js")

    args = ctx.actions.args()
    args.set_param_file_format("multiline")
    args.use_param_file("@%s", use_always = True)
    args.add("--mode", "raw")
    args.add("--tmp_dir", out_dir.path + ".tmp")
    args.add("--compiler_main", "org.jetbrains.kotlin.cli.js.K2JSCompiler")
    for f in tc.jvm_compiler_classpath:
        args.add("--compiler_classpath", f.path)
    args.add("--")
    args.add("-Xir-produce-js")
    args.add("-Xinclude=" + include.path)
    args.add_joined("-libraries", libraries, join_with = ":")
    args.add("-ir-output-dir", out_dir.path)
    args.add("-ir-output-name", "test")
    if target == "wasm_js":
        args.add("-Xwasm")
        args.add("-Xwasm-target=wasm-js")
    else:
        args.add("-module-kind", "commonjs")
        args.add("-Xir-minimized-member-names=false")
    ctx.actions.run(
        mnemonic = "KotlinJsLink",
        progress_message = "Linking Kotlin %{label} (" + target + ")",
        executable = tc.builder,
        arguments = [args],
        inputs = depset([include] + libraries),
        tools = tc.jvm_compiler_classpath,
        outputs = [out_dir],
        execution_requirements = {
            "supports-workers": "1",
            "worker-key-mnemonic": "KotlinJsCompile",
        },
    )
    node = ctx.file.node
    npm_links = []
    npm_files = []
    for pkg, name in ctx.attr.npm_packages.items():
        files = pkg.files.to_list()
        npm_files.extend(files)
        root = files[0].short_path.split("/")[:2]
        npm_links.append('mkdir -p "$run/node_modules/%s" && rmdir "$run/node_modules/%s" && ln -s "$main/%s" "$run/node_modules/%s"' % (name, name, "/".join(root), name))
    runner = ctx.actions.declare_file(ctx.label.name + ".sh")
    ctx.actions.write(runner, _RUNNER.format(
        dir = out_dir.short_path,
        node = node.short_path,
        harness = ctx.file._harness.short_path,
        node_flags = "",
        entry = "test.mjs" if target == "wasm_js" else "test.js",
        npm_links = "\n".join(npm_links),
    ), is_executable = True)
    return [DefaultInfo(
        executable = runner,
        runfiles = ctx.runfiles(files = [out_dir, node, ctx.file._harness] + npm_files),
    )]

kmp_web_test = rule(
    implementation = _kmp_web_test_impl,
    test = True,
    attrs = {
        "test_klib": attr.label(providers = [KlibInfo], mandatory = True),
        "target": attr.string(mandatory = True),
        "npm_packages": attr.label_keyed_string_dict(
            doc = "npm packages the bundle imports: package files -> package name.",
        ),
        "node": attr.label(mandatory = True, allow_single_file = True, cfg = "target", doc = "The node binary."),
        "_harness": attr.label(default = "//kotlin/testing:web_test_runner.js", allow_single_file = True),
    },
    toolchains = [WEB_TOOLCHAIN_TYPE],
)
