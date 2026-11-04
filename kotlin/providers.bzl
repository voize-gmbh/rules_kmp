"""Providers shared by the Kotlin rules."""

KlibInfo = provider(
    doc = "Kotlin library compiled to klib for a Native, JS or Wasm target.",
    fields = {
        "target": "Kotlin target name, e.g. ios_arm64, js, wasm_js.",
        "klibs": "list[File]: the klibs of this library (a Maven artifact may ship cinterop klibs too).",
        "transitive_klibs": "depset[File]: klibs of this library and everything it depends on.",
        "header_klibs": "list[File]: what dependents compile against instead of `klibs`: the ABI-only header klib of a compiled library, the klib itself otherwise.",
        "compile_klibs": "depset[File]: `header_klibs` of this library and everything it depends on.",
        "module_name": "Unique module name, or None for imported libraries.",
        "native_linkopts": "depset[str]: extra linker flags required by native dependencies.",
        "native_link_inputs": "depset[File]: static libraries / frameworks needed when linking.",
        "native_runtime_files": "depset[File] or unset: dynamic frameworks an executable loads at run time.",
        "resources": "depset[File]: Compose resources to bundle into the final binary.",
    },
)

KtCompilerPluginInfo = provider(
    doc = "A Kotlin compiler plugin with the jars for the JVM/JS compiler and Kotlin/Native.",
    fields = {
        "id": "Plugin id used in -P plugin:<id>:key=value options.",
        "jvm_jars": "list[File]: plugin jars for kotlinc (unshaded compiler).",
        "native_jars": "list[File]: plugin jars for Kotlin/Native (embeddable compiler).",
        "options": "list[str]: key=value options.",
    },
)

ComposeResourcesInfo = provider(
    doc = "Compose Multiplatform resources of a library, keyed by the package of its Res class.",
    fields = {
        "package": "Res class package; resources are packaged under composeResources/<package>/.",
        "files": "list[File]: resource files.",
        "root": "str: directory prefix to strip from each file path.",
        "transitive": "depset[struct(package, files, root)] for this library and its dependencies.",
    },
)

NativeLinkInfo = provider(
    doc = "What linking a Kotlin/Native executable needs from native (Objective-C, Swift) libraries.",
    fields = {
        "linkopts": "depset[str]: linker flags; a flag and its value travel as one space-separated entry.",
        "inputs": "depset[File]: static libraries, frameworks and other files the linker reads.",
        "runtime_files": "depset[File]: dynamic framework binaries an executable loads at run time.",
    },
)

KtCompilationInfo = provider(
    doc = "How a Kotlin/JVM target was compiled, for tools that analyse its sources (detekt).",
    fields = {
        "classpath": "depset[File]: the compile classpath, in the order kotlinc saw it.",
        "class_jar": "File: the full class jar.",
        "friend_jars": "list[File]: class jars whose internal declarations the sources see.",
    },
)

NativeCacheInfo = provider(
    doc = "Kotlin/Native static caches (debug builds) of a library and what it depends on.",
    fields = {
        "cached": "bool: this library has a cache; libraries depending on it can have one too.",
        "caches": "depset[File]: cache directories of this library and its dependencies.",
        "dep_caches": "depset[File]: cache directories of its dependencies only.",
        "external_caches": "depset[File]: cache directories of the Maven libraries among them.",
        "abi_caches": "depset[File]: what building a dependent's cache reads from `caches`: their metadata, without the compiled code (KotlinBuilder.writeCacheAbi).",
    },
)
