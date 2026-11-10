package fixture.lib

class Box(val value: Int)

operator fun Box.plus(other: Box): Box = Box(value + other.value)

operator fun Box.getValue(thisRef: Any?, property: Any?): Int = value

fun named(x: Int): Int = x + 1

inline fun inlined(x: Int, block: (Int) -> Int): Int = block(helperForInline(x))

// Inlines another function, so this file's facade gets a source map.
inline fun twice(x: Int): Int = inlined(x) { it } * 2

fun helperForInline(x: Int): Int = x * 2

val namedProperty: Int get() = 42

// v2 puts a declaration here, keeping the line count.
