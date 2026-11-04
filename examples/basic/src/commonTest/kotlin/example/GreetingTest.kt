package example

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue
import kotlinx.coroutines.flow.toList
import kotlinx.coroutines.test.runTest

class GreetingTest {
    @Test
    fun greetsByName() {
        assertEquals("Hello, Ada!", greet("Ada").text)
    }

    @Test
    fun greetsEveryNameInOrder() = runTest {
        val texts = greetings(listOf("Ada", "Grace")).toList().map { it.text }
        assertEquals(listOf("Hello, Ada!", "Hello, Grace!"), texts)
    }

    @Test
    fun serializesToJson() {
        val json = Greeting("Hi", "test").toJson()
        assertEquals("""{"text":"Hi","platform":"test"}""", json)
        assertTrue(greet("Ada").platform.isNotEmpty())
    }
}
