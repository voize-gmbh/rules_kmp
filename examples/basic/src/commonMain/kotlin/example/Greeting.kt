package example

import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.asFlow
import kotlinx.coroutines.flow.map
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json

@Serializable
data class Greeting(val text: String, val platform: String)

expect fun platformName(): String

fun greet(name: String): Greeting = Greeting("Hello, $name!", platformName())

fun greetings(names: List<String>): Flow<Greeting> = names.asFlow().map(::greet)

fun Greeting.toJson(): String = Json.encodeToString(this)
