"""Public API of the Kotlin rules."""

load("//kotlin/private:compile.bzl", _kmp_jvm_library = "kmp_jvm_library", _kmp_jvm_rewrap = "kmp_jvm_rewrap", _kmp_klib = "kmp_klib")
load("//kotlin/private:conventions.bzl", _kmp_conventions = "kmp_conventions")
load(
    "//kotlin/private:kmp.bzl",
    _android_options = "android_options",
    _kmp_library = "kmp_library",
    _kmp_source_sets = "kmp_source_sets",
    _native_options = "native_options",
    _platform_label = "platform_label",
    _test_options = "test_options",
)
load("//kotlin/private:jvm.bzl", _kmp_jvm_module = "kmp_jvm_module")
load("//kotlin/private:ksp.bzl", _kmp_ksp = "kmp_ksp")
load("//kotlin/private:native.bzl", "MACOS_ONLY", _kmp_cinterop = "kmp_cinterop", _kmp_native_framework = "kmp_native_framework", _kmp_native_test = "kmp_native_test")
load("//kotlin/private:plugin.bzl", _kmp_compiler_plugin = "kmp_compiler_plugin")
load(
    "//kotlin/private:testing.bzl",
    _TEST_ON_EXEC_PLATFORM = "TEST_ON_EXEC_PLATFORM",
    _exec_platform_jdk = "exec_platform_jdk",
    _kmp_jvm_jni_test = "kmp_jvm_jni_test",
    _kmp_jvm_test = "kmp_jvm_test",
    _kmp_jvm_test_binary = "kmp_jvm_test_binary",
    _test_on_exec_platform_info = "test_on_exec_platform_info",
)
load("//kotlin/private:toolchain.bzl", _kotlin_toolchain = "kotlin_toolchain")

TEST_ON_EXEC_PLATFORM = _TEST_ON_EXEC_PLATFORM
android_options = _android_options
exec_platform_jdk = _exec_platform_jdk
kmp_compiler_plugin = _kmp_compiler_plugin
kmp_conventions = _kmp_conventions
kmp_jvm_jni_test = _kmp_jvm_jni_test
kmp_jvm_library = _kmp_jvm_library
kmp_jvm_module = _kmp_jvm_module
kmp_jvm_rewrap = _kmp_jvm_rewrap
kmp_jvm_test = _kmp_jvm_test
kmp_jvm_test_binary = _kmp_jvm_test_binary
kmp_klib = _kmp_klib
kmp_ksp = _kmp_ksp
kmp_library = _kmp_library
kmp_source_sets = _kmp_source_sets
kotlin_toolchain = _kotlin_toolchain
native_options = _native_options
platform_label = _platform_label
test_on_exec_platform_info = _test_on_exec_platform_info
test_options = _test_options

def kmp_cinterop(target_compatible_with = MACOS_ONLY, **kwargs):
    """The kmp_cinterop rule, for a macOS target platform only."""
    _kmp_cinterop(target_compatible_with = target_compatible_with, **kwargs)

def kmp_native_framework(target_compatible_with = MACOS_ONLY, **kwargs):
    """The kmp_native_framework rule, for a macOS target platform only."""
    _kmp_native_framework(target_compatible_with = target_compatible_with, **kwargs)

def kmp_native_test(target_compatible_with = MACOS_ONLY, **kwargs):
    """The kmp_native_test rule, for a macOS target platform only."""
    _kmp_native_test(target_compatible_with = target_compatible_with, **kwargs)
