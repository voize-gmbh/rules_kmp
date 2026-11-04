# rules_kmp example: a small multiplatform library

One `kmp_library` for JVM, Android, iOS (device and simulator) and macOS:

- `commonMain` uses kotlinx-coroutines and kotlinx-serialization (with its compiler plugin), and
  declares an `expect fun` that `jvmMain`, `androidMain` and `nativeMain` implement.
- `commonTest` runs on the JVM (JUnit 5) and on macOS as a Kotlin/Native test binary. The iOS
  tests are built but tagged `manual`, as they need a simulator or a device.
- `Greeting_ios_arm64` and `Greeting_ios_simulator_arm64` are static Apple frameworks of it.

It depends on rules_kmp alone, with no patched rule sets.

## Requirements

- macOS on Apple silicon with Xcode, for the Kotlin/Native targets.
- An Android SDK with platform 36 in `ANDROID_HOME`, for the Android target.

## Commands

```sh
bazel build //...
bazel test //...
```

Third-party libraries are pinned in `maven_lock.json`. After changing a `maven.artifact` in
`MODULE.bazel`, resolve them again:

```sh
bazel run @maven//:pin
```
