"""What the Android wrappers of Kotlin and Maven libraries share."""

EMPTY_MANIFEST = Label("//android:EmptyManifest.xml")

# R class package of the Android wrappers that have no resources of their own.
GENERATED_PACKAGE = "rules_kmp.generated"
