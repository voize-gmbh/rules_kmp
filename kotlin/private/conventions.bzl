"""Repository-wide settings of the module macros (kmp_library, kmp_jvm_module)."""

def kmp_conventions(
        maven = "@maven",
        jvm_test_runner = Label("@kmp_maven_libs//:jvm_test_runner"),
        android_jar = None,
        android_host_test = None,
        android_device_test = None,
        source_set_groups = {},
        native_test_bundle_id_prefix = "test.",
        web_test_node = None,
        web_test_npm_packages = {},
        file_labels = None):
    """Settings shared by every module of a repository, usually bound once in a wrapper macro.

    Args:
      maven: The hub repository of the maven extension. A dependency `<maven>//:foo` becomes
        `<maven>//<platform>:foo`, and kotlin-test is taken from there.
      jvm_test_runner: Runtime dependency of JVM tests that provides the test runner and the JUnit
        engines. The default builds //kotlin/testing:BazelJUnitRunner.java against the JUnit
        Platform of the hub's jvm platform.
      android_jar: The android.jar Android code compiles against.
      android_host_test: Macro that declares the Android host test of a module, called with
        name, main_label, lib_kwargs (kmp_jvm_library arguments of the test sources), deps,
        runtime_deps, test, android, resource_dirs, data and tags.
      android_device_test: Macro that declares the Android device test of a module, called with
        name, main_label, namespace, lib_kwargs, deps, runtime_deps, manifest, assets,
        assets_dir, runner_args and tags.
      source_set_groups: Shared source sets between common and some platforms, like those a Gradle
        convention plugin adds to the default hierarchy: group name -> platforms. For example
        {"concurrent": ["jvm", "ios_arm64"]} adds concurrentMain and concurrentTest.
      native_test_bundle_id_prefix: Prefix of the bundle id of Kotlin/Native test binaries.
      web_test_node: The node binary that runs JS and Wasm tests.
      web_test_npm_packages: npm packages the JS and Wasm test bundles import: package files ->
        package name.
      file_labels: Macro that maps the resource, asset and test data files of a module (paths
        relative to its package) to the labels used in their place, one for one, e.g. targets that
        fetch Git LFS objects. The default uses the files themselves.

    Returns:
      A struct for the `conventions` argument of the module macros.
    """
    return struct(
        maven = maven,
        jvm_test_runner = jvm_test_runner,
        android_jar = android_jar,
        android_host_test = android_host_test,
        android_device_test = android_device_test,
        source_set_groups = source_set_groups,
        native_test_bundle_id_prefix = native_test_bundle_id_prefix,
        web_test_node = web_test_node,
        web_test_npm_packages = web_test_npm_packages,
        file_labels = file_labels,
    )

def file_labels(conventions, files):
    """The labels that stand for a module's resource, asset or test data files."""
    return conventions.file_labels(files) if conventions.file_labels else files

def require(conventions, field, what):
    """The value of a conventions field that `what` needs, failing if it is unset."""
    value = getattr(conventions, field)
    if value == None:
        fail("%s needs kmp_conventions(%s = ...)" % (what, field))
    return value
