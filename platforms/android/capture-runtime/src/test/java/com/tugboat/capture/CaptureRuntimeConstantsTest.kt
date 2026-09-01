package com.tugboat.capture

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Test

class CaptureRuntimeConstantsTest {
    @Test
    fun nativeFloorAndDefaults() {
        assertEquals(24, CaptureRuntime.MIN_NATIVE_API)
        assertEquals(2_000L, CaptureRuntime.DEFAULT_TIMEOUT_MS)
        assertEquals(80, CaptureRuntime.JPEG_QUALITY)
        assertFalse(CaptureStatus.Cancelled.name.isEmpty())
    }

    @Test
    fun repeatedDisposeIsSafe() {
        val runtime = CaptureRuntime()
        runtime.dispose()
        runtime.dispose()
        runtime.cancel(1L)
    }

    @Test
    fun repeatedInitializationCreatesIndependentRuntimes() {
        val first = CaptureRuntime()
        val second = CaptureRuntime()
        first.dispose()
        second.dispose()
        first.dispose()
    }
}
