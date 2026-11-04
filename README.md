# rules_kmp

Bazel rules for Kotlin Multiplatform. A `kmp_library` builds a module's common and platform
source sets for the JVM, Android, Apple platforms (Kotlin/Native) and JS/Wasm, and runs its tests
on each platform.

**Status: early.** The rules come from the Bazel build of a large Kotlin Multiplatform monorepo,
where they build every module, but they have seen little use outside it. Expect breaking changes.

## What's in it

- `kmp_library`: a multiplatform module laid out as in Gradle (`src/<sourceSet>/kotlin`), with
  Kotlin's default source set hierarchy and tests per platform.
- `kmp_jvm_module`, `kmp_jvm_library`, `kmp_jvm_test`: plain Kotlin/JVM.
- `kmp_native_framework`, `kmp_cinterop`, `kmp_native_test`: Kotlin/Native for iOS and macOS,
  with Apple frameworks, C and Objective-C interop, and tests on the host or an iOS simulator.
- `kmp_compiler_plugin`, `kmp_ksp`: compiler plugins and KSP.
- A Maven extension that pins third-party libraries for each platform. `bazel run @maven//:pin`
  resolves the declared artifacts with Gradle, which picks the right variant of each library for
  each platform (klibs for Kotlin/Native, AARs for Android), and writes a lock file.

## Kotlin version

Each release supports exactly one Kotlin version: currently 2.4.21 (`KOTLIN_VERSION` in
`kotlin/version.bzl`).

## Requirements

- Bazel 9.
- macOS with Xcode for the Apple targets.
- An Android SDK for the Android targets.

## Getting started

rules_kmp is not on the Bazel Central Registry yet. Depend on a commit:

```starlark
bazel_dep(name = "rules_kmp")
git_override(
    module_name = "rules_kmp",
    remote = "https://github.com/voize-gmbh/rules_kmp.git",
    commit = "<commit>",
)
```

[`examples/basic`](examples/basic) is a complete workspace: a library for the JVM, Android, iOS
and macOS that uses kotlinx-coroutines and kotlinx-serialization, with its tests. Its README has
the commands.

## License

Apache License 2.0. See [LICENSE](LICENSE) and [NOTICE](NOTICE).
