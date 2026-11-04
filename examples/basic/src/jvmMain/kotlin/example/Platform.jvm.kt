package example

actual fun platformName(): String = "JVM " + System.getProperty("java.specification.version")
