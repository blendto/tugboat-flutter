package com.tugboat.capture

import android.view.View
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.assertEquals
import org.junit.Test
import org.junit.runner.RunWith
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

@RunWith(AndroidJUnit4::class)
class CaptureRuntimeLifecycleTest {
    @Test
    fun disposeIsIdempotentAndRejectsCapture() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val runtime = CaptureRuntime()
        runtime.dispose()
        runtime.dispose()
        val latch = CountDownLatch(1)
        var status: CaptureStatus? = null
        runtime.capture(
            View(context),
            CaptureRequest(requestId = 1, pixelWidth = 8, pixelHeight = 8, force = true),
        ) { result ->
            status = result.status
            latch.countDown()
        }
        latch.await(2, TimeUnit.SECONDS)
        assertEquals(CaptureStatus.Disposed, status)
    }

    @Test
    fun cancelWithoutInFlightCaptureIsIgnored() {
        val runtime = CaptureRuntime()
        runtime.cancel(99L)
        runtime.dispose()
    }

    @Test
    fun plainViewReportsUnsupportedRenderMode() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val runtime = CaptureRuntime()
        val latch = CountDownLatch(1)
        var status: CaptureStatus? = null
        runtime.capture(
            View(context),
            CaptureRequest(requestId = 2, pixelWidth = 8, pixelHeight = 8, force = true),
        ) { result ->
            status = result.status
            latch.countDown()
        }
        latch.await(3, TimeUnit.SECONDS)
        runtime.dispose()
        assertEquals(CaptureStatus.UnsupportedRenderMode, status)
    }
}
