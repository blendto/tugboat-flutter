package com.tugboat.capture

import android.app.Activity
import android.view.View
import android.view.WindowManager
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.ConscryptMode
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference

/** Public entry points: routing, API floors and the secure-window branch. */
@RunWith(RobolectricTestRunner::class)
@ConscryptMode(ConscryptMode.Mode.OFF)
class WindowCaptureRuntimeTest {
    private val runtime = CaptureRuntime()
    private val request = CaptureRequest(requestId = 1, pixelWidth = 8, pixelHeight = 8, force = true)

    @After
    fun tearDown() {
        runtime.dispose()
    }

    private fun activity(): Activity = Robolectric.buildActivity(Activity::class.java).setup().get()

    private fun await(start: ((CaptureResult) -> Unit) -> Unit): CaptureResult {
        val latch = CountDownLatch(1)
        val result = AtomicReference<CaptureResult>()
        start { result.set(it); latch.countDown() }
        assertTrue(latch.await(5, TimeUnit.SECONDS))
        return result.get()
    }

    private fun assertFrameless(result: CaptureResult, status: CaptureStatus) {
        assertEquals(status, result.status)
        assertEquals(request.requestId, result.requestId)
        assertNull(result.coverage)
        assertEquals(0, result.jpeg.size)
        assertEquals("", result.contentHash)
    }

    @Test
    @Config(sdk = [26])
    fun secureWindowReturnsSecureWindowWithoutAFrame() {
        val window = activity().window
        window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)

        assertFrameless(await { runtime.capture(window, request, it) }, CaptureStatus.SecureWindow)
    }

    @Test
    @Config(sdk = [25])
    fun windowCaptureBelowApi26IsUnsupportedWhileTheViewFloorStays24() {
        val activity = activity()

        assertFrameless(await { runtime.capture(activity.window, request, it) }, CaptureStatus.UnsupportedApi)
        assertFrameless(
            await { runtime.capture(View(activity), request, it) },
            CaptureStatus.UnsupportedRenderMode,
        )
    }

    @Test
    @Config(sdk = [25])
    fun apiGateRunsBeforeTheSecureCheck() {
        val window = activity().window
        window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)

        assertFrameless(await { runtime.capture(window, request, it) }, CaptureStatus.UnsupportedApi)
    }

    @Test
    @Config(sdk = [23])
    fun viewCaptureBelowApi24IsUnsupported() {
        assertFrameless(await { runtime.capture(View(activity()), request, it) }, CaptureStatus.UnsupportedApi)
    }

    @Test
    @Config(sdk = [26])
    fun windowCaptureAfterDisposeIsDisposed() {
        val window = activity().window
        runtime.dispose()

        assertFrameless(await { runtime.capture(window, request, it) }, CaptureStatus.Disposed)
    }

    @Test
    @Config(sdk = [26])
    fun windowCaptureCancelledBeforeItRunsIsCancelled() {
        val window = activity().window
        runtime.cancel(request.requestId)

        assertFrameless(await { runtime.capture(window, request, it) }, CaptureStatus.Cancelled)
    }
}
