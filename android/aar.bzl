"""kmp_android_aar: a kmp_library's Android target as the AAR the Android Gradle plugin publishes."""

load("@rules_android//providers:providers.bzl", "AndroidLibraryAarInfo")
load("@rules_java//java/common:java_info.bzl", "JavaInfo")
load("//maven:pom.bzl", "MavenPublicationInfo", "maven_coordinates_aspect", "maven_dependencies")

def _kmp_android_aar_impl(ctx):
    out = ctx.actions.declare_file(ctx.label.name + ".aar")
    classes = ctx.attr.classes[JavaInfo].java_outputs[0].class_jar
    args = ctx.actions.args()
    args.add("--classes", classes)
    args.add("--namespace", ctx.attr.namespace)
    args.add("--min_sdk", ctx.attr.min_sdk)
    args.add("--min_compile_sdk", ctx.attr.min_compile_sdk)
    args.add("--android_jar", ctx.file.android_jar)
    args.add_all(ctx.files.proguard_specs, before_each = "--proguard")
    args.add("--out", out)
    inputs = [classes, ctx.file.android_jar] + ctx.files.proguard_specs
    if ctx.attr.resources:
        resources_aar = ctx.attr.resources[AndroidLibraryAarInfo].aar
        args.add("--resources_aar", resources_aar)
        inputs.append(resources_aar)
    ctx.actions.run(
        mnemonic = "KmpAar",
        progress_message = "Packaging %{label}",
        executable = ctx.executable._packager,
        arguments = [args],
        inputs = inputs,
        outputs = [out],
    )
    dependencies = maven_dependencies(ctx.attr.deps)
    return [
        DefaultInfo(files = depset([out])),
        MavenPublicationInfo(
            file = out,
            packaging = "aar",
            dependencies = dependencies.dependencies,
            unpublished = dependencies.unpublished,
        ),
    ]

kmp_android_aar = rule(
    implementation = _kmp_android_aar_impl,
    doc = """The Android library as AGP's bundle<Variant>Aar writes it: its own classes (without R
classes), manifest, resources, assets, consumer keep rules, R.txt of its own resources and
aar-metadata.properties. kmp_library declares one per Android target as `<name>_android_aar`.""",
    attrs = {
        "classes": attr.label(mandatory = True, providers = [JavaInfo], doc = "The library's Kotlin compilation."),
        "resources": attr.label(providers = [AndroidLibraryAarInfo], doc = "The android_library of its manifest, resources and assets."),
        "namespace": attr.string(mandatory = True),
        "min_sdk": attr.string(mandatory = True),
        "min_compile_sdk": attr.string(mandatory = True, doc = "AGP's minCompileSdk, by default the library's compileSdk."),
        "android_jar": attr.label(mandatory = True, allow_single_file = [".jar"], doc = "The android.jar the library compiles against, for the platform attributes in R.txt."),
        "proguard_specs": attr.label_list(allow_files = True, doc = "Consumer keep rules, packaged as proguard.txt."),
        "deps": attr.label_list(
            aspects = [maven_coordinates_aspect],
            doc = "The library's direct runtime dependencies, for the POM (see maven_pom).",
        ),
        "_packager": attr.label(default = "//android:package_aar", executable = True, cfg = "exec"),
    },
)
