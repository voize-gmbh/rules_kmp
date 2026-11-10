"""Repository rules for the pinned Kotlin compiler distributions."""

_KOTLINC_BUILD = """
package(default_visibility = ["//visibility:public"])

exports_files(glob(["lib/*.jar", "lib/*.klib"]))

filegroup(
    name = "compiler_classpath",
    srcs = [
        "lib/kotlin-compiler.jar",
        "lib/kotlin-stdlib.jar",
        "lib/kotlin-reflect.jar",
        "lib/kotlin-script-runtime.jar",
        "lib/kotlinx-coroutines-core-jvm.jar",
        "lib/annotations-13.0.jar",
    ],
)

filegroup(name = "jvm_abi_gen", srcs = ["lib/jvm-abi-gen.jar"])

filegroup(name = "serialization_plugin", srcs = ["lib/kotlinx-serialization-compiler-plugin.jar"])

filegroup(name = "compose_plugin", srcs = ["lib/compose-compiler-plugin.jar"])

filegroup(name = "allopen_plugin", srcs = ["lib/allopen-compiler-plugin.jar"])

filegroup(name = "noarg_plugin", srcs = ["lib/noarg-compiler-plugin.jar"])

filegroup(name = "parcelize_plugin", srcs = ["lib/parcelize-compiler.jar"])

filegroup(name = "power_assert_plugin", srcs = ["lib/power-assert-compiler-plugin.jar"])

filegroup(name = "sam_with_receiver_plugin", srcs = ["lib/sam-with-receiver-compiler-plugin.jar"])

filegroup(name = "stdlib_js_klib", srcs = ["lib/kotlin-stdlib-js.klib"])

filegroup(name = "stdlib_wasm_js_klib", srcs = ["lib/kotlin-stdlib-wasm-js.klib"])

filegroup(name = "test_js_klib", srcs = ["lib/kotlin-test-js.klib"])
"""

def _kotlin_compiler_repository_impl(rctx):
    rctx.download_and_extract(
        url = rctx.attr.urls,
        sha256 = rctx.attr.sha256,
        stripPrefix = "kotlinc",
    )
    rctx.file("BUILD.bazel", _KOTLINC_BUILD)
    rctx.file("version.bzl", "KOTLIN_VERSION = %r\n" % rctx.attr.version)
    return rctx.repo_metadata(reproducible = True)

kotlin_compiler_repository = repository_rule(
    implementation = _kotlin_compiler_repository_impl,
    attrs = {
        "urls": attr.string_list(mandatory = True),
        "sha256": attr.string(mandatory = True),
        "version": attr.string(mandatory = True),
    },
)

_NATIVE_TARGETS = ["ios_arm64", "ios_simulator_arm64", "ios_x64", "macos_arm64", "macos_x64"]

_KONAN_BUILD_HEADER = """
package(default_visibility = ["//visibility:public"])

exports_files(["dist/konan/konan.properties", "data/dependencies/.extracted"])

filegroup(name = "compiler_jar", srcs = ["dist/konan/lib/kotlin-native-compiler-embeddable.jar"])

filegroup(name = "konan_home_marker", srcs = ["dist/konan/konan.properties"])

filegroup(
    name = "compiler_common",
    srcs = glob([
        "dist/konan/konan.properties",
        "dist/konan/compiler.fingerprint",
        "dist/konan/lib/**",
        "dist/konan/nativelib/**",
        "dist/tools/**",
        "dist/klib/common/**",
    ], allow_empty = True),
)

# data/dependencies/cache is where the compiler takes its lock when it runs: a machine that has run
# it locally would otherwise have one more input, and other cache keys, than one that hasn't.
filegroup(
    name = "toolchain_deps",
    srcs = glob(["data/**"], exclude = [
        "data/**/* *",
        "data/dependencies/cache/**",
    ]),
)
"""

# What building static caches needs without Xcode: LLVM's clang compiles the generated bitcode, and
# the libtool stand-in archives the objects. Every host builds them this way, so they match.
_KONAN_APPLE_TOOLCHAIN_BUILD = """
filegroup(
    name = "apple_toolchain",
    srcs = glob(["apple-toolchain/**", "apple-sdk/**"]),
)

filegroup(
    name = "cache_deps",
    srcs = glob([
        "data/dependencies/.extracted",
        "data/dependencies/{llvm}/bin/clang*",
        "data/dependencies/{llvm}/bin/llvm-ar",
        "data/dependencies/libffi-*/**",
    ]),
)
"""

# Apple's `libtool -static`, as Kotlin/Native calls it to archive a static cache, on llvm-ar.
_LIBTOOL = """#!/bin/sh
set -eu
llvm_ar="$(dirname "$0")/../../../data/dependencies/{llvm}/bin/llvm-ar"
out=""
set -- "$@" --end
while [ "$1" != --end ]; do
  case "$1" in
    -D|-static|-no_warning_for_no_symbols) ;;
    -o) out="$2"; shift ;;
    -arch_only) shift ;;
    -filelist) while IFS= read -r f; do set -- "$@" "$f"; done < "$2"; shift ;;
    -*) echo "libtool: unsupported option $1" >&2; exit 1 ;;
    *) set -- "$@" "$1" ;;
  esac
  shift
done
shift
rm -f "$out"
# L adds the members of archives among the inputs rather than the archives themselves.
exec "$llvm_ar" qcLsD --format=darwin "$out" "$@"
"""

_KONAN_TARGET_BUILD = """
filegroup(
    name = "target_{t}",
    srcs = [":compiler_common"] + glob([
        "dist/konan/targets/{t}/**",
        "dist/klib/platform/{t}/**",
    ], allow_empty = True),
)

filegroup(
    name = "platform_def_{t}",
    srcs = glob(["dist/konan/platformDef/{t}/**"], allow_empty = True),
)

filegroup(
    name = "system_cache_{t}",
    srcs = glob(["dist/klib/cache/{t}-gSTATIC-system/**"], allow_empty = True),
)
"""

def _kotlin_native_repository_impl(rctx):
    rctx.download_and_extract(
        url = rctx.attr.dist_urls,
        sha256 = rctx.attr.dist_sha256,
        stripPrefix = rctx.attr.dist_strip_prefix,
        output = "dist",
    )
    extracted = []
    for name, spec in rctx.attr.dependencies.items():
        url, sha256 = spec[0], spec[1]
        rctx.download_and_extract(
            url = url,
            sha256 = sha256,
            output = "data/dependencies",
        )
        extracted.append(name)
    rctx.file("data/dependencies/.extracted", "\n".join(sorted(extracted)) + "\n")
    build = _KONAN_BUILD_HEADER
    for t in _NATIVE_TARGETS:
        build += _KONAN_TARGET_BUILD.format(t = t)
    if rctx.attr.apple_dist_urls:
        _add_apple_targets(rctx)
    if rctx.attr.apple_toolchain_llvm:
        rctx.file("apple-toolchain/usr/bin/libtool", _LIBTOOL.replace("{llvm}", rctx.attr.apple_toolchain_llvm), executable = True)
        rctx.file("apple-sdk/README", "Building static caches reads nothing from the SDK.\n")
        build += _KONAN_APPLE_TOOLCHAIN_BUILD.format(llvm = rctx.attr.apple_toolchain_llvm)
    rctx.file("BUILD.bazel", build)
    return rctx.repo_metadata(reproducible = True)

def _add_apple_targets(rctx):
    """Adds what only the macOS distributions ship for Apple targets.

    The runtime bitcode and the stdlib and platform library caches don't depend on the host. The
    macOS compiler fingerprint makes static caches built here record the compiler that links them,
    as those built on a Mac do.
    """
    rctx.download_and_extract(
        url = rctx.attr.apple_dist_urls,
        sha256 = rctx.attr.apple_dist_sha256,
        stripPrefix = rctx.attr.apple_dist_strip_prefix,
        output = "apple_dist",
    )
    for t in _NATIVE_TARGETS:
        rctx.rename("apple_dist/konan/targets/" + t, "dist/konan/targets/" + t)
        cache = "klib/cache/%s-gSTATIC-system" % t
        if rctx.path("apple_dist/" + cache).exists:
            rctx.rename("apple_dist/" + cache, "dist/" + cache)
    rctx.delete("dist/konan/compiler.fingerprint")
    rctx.rename("apple_dist/konan/compiler.fingerprint", "dist/konan/compiler.fingerprint")
    rctx.delete("apple_dist")

kotlin_native_repository = repository_rule(
    implementation = _kotlin_native_repository_impl,
    attrs = {
        "version": attr.string(mandatory = True),
        "dist_urls": attr.string_list(mandatory = True),
        "dist_sha256": attr.string(mandatory = True),
        "dist_strip_prefix": attr.string(mandatory = True),
        "dependencies": attr.string_list_dict(),
        "apple_dist_urls": attr.string_list(doc = "A macOS distribution of the same version, for Apple targets on other hosts."),
        "apple_dist_sha256": attr.string(),
        "apple_dist_strip_prefix": attr.string(),
        "apple_toolchain_llvm": attr.string(doc = "The dependency whose clang and llvm-ar build static caches of Apple targets without Xcode."),
    },
)

_PATCHED_SOURCES_BUILD = """
package(default_visibility = ["//visibility:public"])

filegroup(name = "srcs", srcs = {srcs})
"""

def _kotlin_patched_sources_repository_impl(rctx):
    for path, sha256 in rctx.attr.files.items():
        rctx.download(
            url = "https://raw.githubusercontent.com/JetBrains/kotlin/v%s/%s" % (rctx.attr.version, path),
            output = path,
            sha256 = sha256,
        )
    for patch in rctx.attr.patches:
        rctx.patch(patch, strip = 1)
    rctx.file("BUILD.bazel", _PATCHED_SOURCES_BUILD.format(srcs = repr(sorted(rctx.attr.files.keys()))))
    return rctx.repo_metadata(reproducible = True)

kotlin_patched_sources_repository = repository_rule(
    implementation = _kotlin_patched_sources_repository_impl,
    doc = "Files of the Kotlin repository at a release tag, with patches applied.",
    attrs = {
        "version": attr.string(mandatory = True),
        "files": attr.string_dict(mandatory = True, doc = "Path in the repository -> sha256."),
        "patches": attr.label_list(),
    },
)
