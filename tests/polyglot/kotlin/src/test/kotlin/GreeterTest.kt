package smoke

import kotlin.test.Test
import kotlin.test.assertEquals

class GreeterTest {
    @Test
    fun greetsWithJavaSum() {
        assertEquals("hello, alissa (5)", greet("alissa"))
    }
}
