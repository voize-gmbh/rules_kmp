"""The kotlin module extension: the pinned Kotlin compilers that rules_kmp's toolchains use."""

load("//kotlin:version.bzl", "KOTLIN_VERSION")
load("//repositories:kotlin.bzl", "kotlin_compiler_repository", "kotlin_native_repository", "kotlin_patched_sources_repository")

def _disabled_repository_impl(rctx):
    fail(rctx.attr.message)

_disabled_repository = repository_rule(
    implementation = _disabled_repository_impl,
    attrs = {"message": attr.string(mandatory = True)},
)

def _kotlin_impl(module_ctx):
    kotlin_compiler_repository(
        name = "kotlin_compiler",
        urls = ["https://github.com/JetBrains/kotlin/releases/download/v{v}/kotlin-compiler-{v}.zip".format(v = KOTLIN_VERSION)],
        sha256 = "7cc140e76daf416a0424a5557f99afd7ca89ebd463ea1101261e3e01c33e75cd",
        version = KOTLIN_VERSION,
    )
    kotlin_native_repository(
        name = "kotlin_native_macos_aarch64",
        version = KOTLIN_VERSION,
        dist_urls = [
            "https://repo1.maven.org/maven2/org/jetbrains/kotlin/kotlin-native-prebuilt/{v}/kotlin-native-prebuilt-{v}-macos-aarch64.tar.gz".format(v = KOTLIN_VERSION),
            "https://github.com/JetBrains/kotlin/releases/download/v{v}/kotlin-native-prebuilt-macos-aarch64-{v}.tar.gz".format(v = KOTLIN_VERSION),
        ],
        dist_sha256 = "bf4edb526d91e17d0862102f69250525d788e79011f86c2c64362749adf260ae",
        dist_strip_prefix = "kotlin-native-prebuilt-macos-aarch64-{v}".format(v = KOTLIN_VERSION),
        # The compiler fetches these into ~/.konan on first use. They are listed in
        # konan/konan.properties of the distribution (llvm.macos_arm64.user, libffiDir.macos_arm64).
        dependencies = {
            "llvm-21-aarch64-macos-essentials-97": [
                "https://download.jetbrains.com/kotlin/native/resources/llvm/21-aarch64-macos/llvm-21-aarch64-macos-essentials-97.tar.gz",
                "62fd78f090353aa7b2c6601ad6f95bd7a0b0558b18f86978043cc878321b408a",
            ],
            "libffi-3.3-1-macos-arm64": [
                "https://download.jetbrains.com/kotlin/native/libffi-3.3-1-macos-arm64.tar.gz",
                "8ca0102ad5b626e8b1699f311ab098354a90154ea3e44951f28ebdd256862ba9",
            ],
        },
        apple_toolchain_llvm = "llvm-21-aarch64-macos-essentials-97",
    )

    # Compiles Apple klibs on Linux, and with the patched classes below builds their static caches.
    # cinterop and linking need Xcode and stay on macOS.
    kotlin_native_repository(
        name = "kotlin_native_linux_x86_64",
        version = KOTLIN_VERSION,
        dist_urls = [
            "https://repo1.maven.org/maven2/org/jetbrains/kotlin/kotlin-native-prebuilt/{v}/kotlin-native-prebuilt-{v}-linux-x86_64.tar.gz".format(v = KOTLIN_VERSION),
            "https://github.com/JetBrains/kotlin/releases/download/v{v}/kotlin-native-prebuilt-linux-x86_64-{v}.tar.gz".format(v = KOTLIN_VERSION),
        ],
        dist_sha256 = "4935d8c8da90a2d2a8ff51da7d2c264c0d6026e1d35a8f169e218d9209965678",
        dist_strip_prefix = "kotlin-native-prebuilt-linux-x86_64-{v}".format(v = KOTLIN_VERSION),
        # konan/konan.properties: llvm.linux_x64.user, libffiDir.linux_x64.
        dependencies = {
            "llvm-21-x86_64-linux-essentials-116": [
                "https://download.jetbrains.com/kotlin/native/resources/llvm/21-x86_64-linux/llvm-21-x86_64-linux-essentials-116.tar.gz",
                "0b1f290214dd7ec20e2506210967e0ebd735cdefc3a3b4485bbccb439fa78e5b",
            ],
            "libffi-3.2.1-2-linux-x86-64": [
                "https://download.jetbrains.com/kotlin/native/libffi-3.2.1-2-linux-x86-64.tar.gz",
                "9d817bbca098a2fa0f1d5a8b9e57674c30d100bb4c6aeceff18d8acc5b9f382c",
            ],
        },
        apple_dist_urls = [
            "https://repo1.maven.org/maven2/org/jetbrains/kotlin/kotlin-native-prebuilt/{v}/kotlin-native-prebuilt-{v}-macos-aarch64.tar.gz".format(v = KOTLIN_VERSION),
            "https://github.com/JetBrains/kotlin/releases/download/v{v}/kotlin-native-prebuilt-macos-aarch64-{v}.tar.gz".format(v = KOTLIN_VERSION),
        ],
        apple_dist_sha256 = "bf4edb526d91e17d0862102f69250525d788e79011f86c2c64362749adf260ae",
        apple_dist_strip_prefix = "kotlin-native-prebuilt-macos-aarch64-{v}".format(v = KOTLIN_VERSION),
        apple_toolchain_llvm = "llvm-21-x86_64-linux-essentials-116",
    )

    # JetBrains publishes no Linux arm64 distribution. This one is built from the same release tag,
    # with JetBrains' standard library; a Kotlin bump needs a new release of it.
    if any([mod.tags.linux_arm64 for mod in module_ctx.modules]):
        arm64_release = "https://github.com/voize-gmbh/kotlin/releases/download/v{v}-linux-arm64/".format(v = KOTLIN_VERSION)
        kotlin_native_repository(
            name = "kotlin_native_linux_aarch64",
            version = KOTLIN_VERSION,
            dist_urls = [arm64_release + "kotlin-native-prebuilt-linux-aarch64-{v}.tar.gz".format(v = KOTLIN_VERSION)],
            dist_sha256 = "e7dfc692c1e0b1d0ad9ada67031a67b0544974ba77220445c21efc7949281ea3",
            dist_strip_prefix = "kotlin-native-prebuilt-linux-aarch64-{v}".format(v = KOTLIN_VERSION),
            # JetBrains hosts no LLVM or libffi for this host either; they come with the release.
            dependencies = {
                "llvm-21-aarch64-linux-essentials-1": [
                    arm64_release + "llvm-21-aarch64-linux-essentials-1.tar.gz",
                    "35e9a2566bf7cb44de427669d010117e98148ca5ea1a4ffef291218581d376a9",
                ],
                "libffi-3.4.6-1-linux-aarch64": [
                    arm64_release + "libffi-3.4.6-1-linux-aarch64.tar.gz",
                    "ad212a7541b98ed2a4ebb3b510f4cdebf2919b8b0cc9dd5a321558a5f4282b13",
                ],
            },
            apple_dist_urls = [
                "https://repo1.maven.org/maven2/org/jetbrains/kotlin/kotlin-native-prebuilt/{v}/kotlin-native-prebuilt-{v}-macos-aarch64.tar.gz".format(v = KOTLIN_VERSION),
                "https://github.com/JetBrains/kotlin/releases/download/v{v}/kotlin-native-prebuilt-macos-aarch64-{v}.tar.gz".format(v = KOTLIN_VERSION),
            ],
            apple_dist_sha256 = "bf4edb526d91e17d0862102f69250525d788e79011f86c2c64362749adf260ae",
            apple_dist_strip_prefix = "kotlin-native-prebuilt-macos-aarch64-{v}".format(v = KOTLIN_VERSION),
            apple_toolchain_llvm = "llvm-21-aarch64-linux-essentials-1",
        )
    else:
        _disabled_repository(
            name = "kotlin_native_linux_aarch64",
            message = "Static caches on Linux arm64 need Kotlin/Native for that host: add kotlin.linux_arm64() to MODULE.bazel.",
        )

    # The compiler enables Apple targets on macOS only; the patch also enables them on other hosts
    # when told where an Apple toolchain is. Its classes go ahead of the compiler jar.
    kotlin_patched_sources_repository(
        name = "kotlin_native_apple_targets_patch",
        version = KOTLIN_VERSION,
        files = {
            "native/utils/src/org/jetbrains/kotlin/konan/target/Apple.kt": "79c1fd6f37c9b83cb9dd643a1a30d262532cfebfd143e474f9d47cd62797ed62",
            "native/utils/src/org/jetbrains/kotlin/konan/target/HostManager.kt": "acc6c767c189f8989ccf24d5623239e051bc670d01772a048958a42fd96192f2",
            "native/utils/src/org/jetbrains/kotlin/konan/target/Platform.kt": "d7be35a14d6b394637f182d62d6b9b375589875116c9d4411996acf4714a5559",
        },
        patches = [Label("//repositories/patches:kotlin_native_apple_targets_on_linux.patch")],
    )

    # The same classes for the Linux arm64 distribution, whose HostManager also knows that host.
    kotlin_patched_sources_repository(
        name = "kotlin_native_apple_targets_patch_linux_arm64",
        version = KOTLIN_VERSION,
        files = {
            "native/utils/src/org/jetbrains/kotlin/konan/target/Apple.kt": "79c1fd6f37c9b83cb9dd643a1a30d262532cfebfd143e474f9d47cd62797ed62",
            "native/utils/src/org/jetbrains/kotlin/konan/target/HostManager.kt": "acc6c767c189f8989ccf24d5623239e051bc670d01772a048958a42fd96192f2",
            "native/utils/src/org/jetbrains/kotlin/konan/target/Platform.kt": "d7be35a14d6b394637f182d62d6b9b375589875116c9d4411996acf4714a5559",
        },
        patches = [
            Label("//repositories/patches:kotlin_native_apple_targets_on_linux.patch"),
            Label("//repositories/patches:kotlin_native_linux_arm64_host.patch"),
        ],
    )

    # Building the cache of a module with large classes took quadratic time. Its classes go ahead of
    # the compiler jar where caches are built.
    kotlin_patched_sources_repository(
        name = "kotlin_native_cache_class_fields_patch",
        version = KOTLIN_VERSION,
        files = {
            "kotlin-native/backend.native/compiler/ir/backend.native/src/org/jetbrains/kotlin/backend/konan/lower/CacheInfoBuilder.kt": "be38ad65ba00dac0eaca10dc417da84713d584e3f47aca3c32136491ad17704c",
            "kotlin-native/backend.native/compiler/ir/backend.native/src/org/jetbrains/kotlin/backend/konan/serialization/CacheSerializationSupport.kt": "e5023c04cef92a6aaf5c23ec326631d74d6b265d0837e5ac826672f77d77da21",
        },
        patches = [Label("//repositories/patches:kotlin_native_cache_class_fields_once.patch")],
    )
    return module_ctx.extension_metadata(reproducible = True)

kotlin = module_extension(
    implementation = _kotlin_impl,
    tag_classes = {
        "linux_arm64": tag_class(
            doc = """Fetches a Linux arm64 build of Kotlin/Native (JetBrains publishes none), released on
github.com/voize-gmbh/kotlin, so that static caches can build on Linux arm64 executors.""",
        ),
    },
)
