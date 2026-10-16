package com.tugboat.android.engine

import org.junit.Assert.assertEquals
import org.junit.Test

class EngineStatusTest {
    @Test
    fun codesAndNamesMirrorTheCHeader() {
        val expected = listOf(
            "ok", "invalid_argument", "abi_mismatch", "malformed_message", "invalid_message",
            "unsupported_message", "contract_mismatch", "message_too_large", "busy",
            "out_of_memory", "internal_error",
        )
        assertEquals(expected, (0..10).map { EngineStatus.fromCode(it).wireName })
        EngineStatus.values().forEach { assertEquals(it, EngineStatus.fromCode(it.code)) }
    }

    @Test
    fun unknownCodesAreInternalErrors() {
        assertEquals(EngineStatus.INTERNAL_ERROR, EngineStatus.fromCode(11))
        assertEquals(EngineStatus.INTERNAL_ERROR, EngineStatus.fromCode(-1))
    }

    @Test
    fun responseDecodesUtf8() {
        val response = EngineResponse(0, "{\"v\":\"é\"}".toByteArray(Charsets.UTF_8))
        assertEquals(EngineStatus.OK, response.status)
        assertEquals("{\"v\":\"é\"}", response.text())
    }
}
