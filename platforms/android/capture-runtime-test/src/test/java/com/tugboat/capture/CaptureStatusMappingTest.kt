package com.tugboat.capture

import org.junit.Assert.assertEquals
import org.junit.Test

class CaptureStatusMappingTest {
    @Test
    fun fallbackStatusesAreStableTokens() {
        assertEquals("UnsupportedApi", CaptureStatus.UnsupportedApi.name)
        assertEquals("UnsupportedRenderMode", CaptureStatus.UnsupportedRenderMode.name)
        assertEquals("SurfaceUnavailable", CaptureStatus.SurfaceUnavailable.name)
        assertEquals("Timeout", CaptureStatus.Timeout.name)
        assertEquals("PixelCopyFailed", CaptureStatus.PixelCopyFailed.name)
        assertEquals("ProcessingFailed", CaptureStatus.ProcessingFailed.name)
        assertEquals("Cancelled", CaptureStatus.Cancelled.name)
        assertEquals("Disposed", CaptureStatus.Disposed.name)
    }

    @Test
    fun coverageHasEngineSurfaceOnly() {
        assertEquals(1, CaptureCoverage.entries.size)
        assertEquals(CaptureCoverage.EngineSurface, CaptureCoverage.entries.single())
    }
}
