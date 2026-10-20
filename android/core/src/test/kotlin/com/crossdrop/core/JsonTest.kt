package com.crossdrop.core

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith

class JsonTest {
    @Test
    fun roundTrip() {
        val m = linkedMapOf<String, Any?>("type" to "x", "v" to 1L, "s" to "é \"q\" \n\u0001", "a" to listOf(1L, true, null), "o" to mapOf("k" to "v"))
        assertEquals(m, Json.parse(Json.write(m)))
    }

    @Test
    fun strictness() {
        for (bad in listOf("{", "{\"a\":1,}", "{\"a\":1}x", "{\"a\":01}", "{\"a\":1,\"a\":2}", "[1,]", "{'a':1}", "{\"a\":\"\u0001\"}", "nul")) {
            assertFailsWith<JsonException>(bad) { Json.parse(bad) }
        }
        assertFailsWith<JsonException> { Json.parse("[".repeat(100) + "]".repeat(100)) }
    }

    @Test
    fun numbersAndEscapes() {
        assertEquals(9007199254740991L, Json.parse("9007199254740991"))
        assertEquals(1.5, Json.parse("1.5"))
        assertEquals("🎉", Json.parse("\"\\ud83c\\udf89\""))
    }

    @Test
    fun messageValidation() {
        assertFailsWith<ProtocolException> { Message.parse("{\"type\":\"hello\"}".toByteArray()) } // missing v
        assertFailsWith<ProtocolException> { Message.parse("{\"type\":\"x\",\"v\":\"1\"}".toByteArray()) }
        val m = Message.parse("{\"type\":\"x\",\"v\":1,\"n\":\"5\"}".toByteArray())
        assertFailsWith<ProtocolException> { m.long("n") } // strings are not numbers
        assertFailsWith<ProtocolException> { Message.parse(byteArrayOf(0x7b, 0xff.toByte(), 0x7d)) } // bad UTF-8
    }
}
