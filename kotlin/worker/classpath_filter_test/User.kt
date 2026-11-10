package fixture.lib

// Same package as the library, so the operators below are used without being imported by name.
class User {
    val delegated: Int by Box(1)

    fun sum(): Int = (Box(1) + Box(2)).value + named(3) + inlined(4) { it } + namedProperty + delegated
}
