package com.tugboat.android.host

import org.json.JSONException
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner

@RunWith(RobolectricTestRunner::class)
class RawJsonTest {
    @Test
    fun membersKeepSourceOrderAndExactText() {
        val text = """ { "z" : 390.0, "a":{"k":[1, "]}"]}, "s":"a\"b}", "n":null,"e":-1.5e-7 } """
        val members = RawJson.members(text)

        assertEquals(listOf("z", "a", "s", "n", "e"), members.keys.toList())
        assertEquals("390.0", members["z"])
        assertEquals("{\"k\":[1, \"]}\"]}", members["a"])
        assertEquals("\"a\\\"b}\"", members["s"])
        assertEquals("null", members["n"])
        assertEquals("-1.5e-7", members["e"])
    }

    @Test
    fun memberKeysAreDecoded() {
        assertEquals(setOf("a\"b", "é"), RawJson.members("{\"a\\\"b\":1,\"\\u00e9\":2}").keys)
    }

    @Test
    fun elementsKeepExactText() {
        assertEquals(
            listOf("{\"type\":\"a\"}", "[1,2]", "\"x,y\"", "true"),
            RawJson.elements("[{\"type\":\"a\"}, [1,2] ,\"x,y\",true]"),
        )
    }

    @Test
    fun emptyContainers() {
        assertEquals(emptyMap<String, String>(), RawJson.members(" { } "))
        assertEquals(emptyList<String>(), RawJson.elements("[]"))
    }

    @Test
    fun malformedInputThrowsJsonException() {
        listOf("", "[]", "{\"a\":1", "{\"a\" 1}", "{\"a\":1}x", "{\"a\":}", "{\"a\":\"open}").forEach { text ->
            assertThrows(text, JSONException::class.java) { RawJson.members(text) }
        }
        assertThrows(JSONException::class.java) { RawJson.elements("{}") }
        assertThrows(JSONException::class.java) { RawJson.elements("[1,") }
    }

    @Test
    fun decodeStringRejectsNonStrings() {
        assertEquals("a/b", RawJson.decodeString("\"a\\/b\""))
        assertThrows(JSONException::class.java) { RawJson.decodeString("12") }
    }
}
