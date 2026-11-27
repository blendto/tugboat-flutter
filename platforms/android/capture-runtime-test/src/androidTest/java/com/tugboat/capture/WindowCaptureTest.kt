package com.tugboat.capture

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Color
import android.os.Build
import android.view.Window
import android.view.WindowManager
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import java.security.MessageDigest
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference
import kotlin.math.abs

/** `capture(window, …)` end to end: PixelCopy, C++ mask fill, JPEG. */
@RunWith(AndroidJUnit4::class)
class WindowCaptureTest {
    @get:Rule
    val timeout = MainThreadTimeout(seconds = 60)

    private val runtime = CaptureRuntime()

    @After
    fun tearDown() {
        runtime.dispose()
    }

    @Test
    fun capturesTheActivityWindowWithTheMaskFilledBeforeEncoding() {
        assumeTrue(Build.VERSION.SDK_INT >= CaptureRuntime.MIN_WINDOW_API)
        ActivityScenario.launch(WindowCaptureActivity::class.java).use { scenario ->
            val (window, width, height) = presentedWindow(scenario)
            val request =
                CaptureRequest(
                    requestId = 1,
                    pixelWidth = width,
                    pixelHeight = height,
                    force = true,
                    masks = listOf(MASK),
                )

            val result = capture(window, request)

            assertEquals(CaptureStatus.Ok, result.status)
            assertEquals(CaptureCoverage.WindowComposite, result.coverage)
            assertEquals(width, result.width)
            assertEquals(height, result.height)
            assertEquals(64, result.dHash.length)
            assertEquals(sha256Hex(result.jpeg), result.contentHash)
            val jpeg = requireNotNull(BitmapFactory.decodeByteArray(result.jpeg, 0, result.jpeg.size))
            assertEquals(width, jpeg.width)
            assertEquals(height, jpeg.height)
            assertColorNear(MASK_FILL, jpeg.at(0.5, 0.5))
            assertColorNear(WindowCaptureActivity.FILL, jpeg.at(0.5, 0.75))
            assertColorNear(WindowCaptureActivity.FILL, jpeg.at(0.1, 0.5))
        }
    }

    /**
     * Masks are taken for the frame being copied: the marker moves after the
     * request is made (in the same main-thread task), and the copied frame's
     * mask covers its new position, not the one the request was made for.
     */
    @Test
    fun suppliedMasksFollowAViewThatMovedBetweenRequestAndCopy() {
        assumeTrue(Build.VERSION.SDK_INT >= CaptureRuntime.MIN_WINDOW_API)
        ActivityScenario.launch(WindowCaptureActivity::class.java).use { scenario ->
            val (window, width, height) = presentedWindow(scenario)
            val drawn = CountDownLatch(1)
            scenario.onActivity {
                it.moveMarkerTo(0.1, 0.1)
                it.afterTwoFrames { drawn.countDown() }
            }
            assertTrue(drawn.await(5, TimeUnit.SECONDS))
            val oldMask = AtomicReference<NormalizedMask>()
            scenario.onActivity { oldMask.set(markerMask(it)) }

            val latch = CountDownLatch(1)
            val result = AtomicReference<CaptureResult>()
            scenario.onActivity { activity ->
                val request = CaptureRequest(5, width, height, force = true, masks = listOf(oldMask.get()))
                runtime.capture(activity.window, request, { MaskSnapshot(listOf(markerMask(activity))) }) {
                    result.set(it)
                    latch.countDown()
                }
                activity.moveMarkerTo(0.5, 0.6)
            }
            assertTrue(latch.await(5, TimeUnit.SECONDS))
            val newMask = AtomicReference<NormalizedMask>()
            scenario.onActivity { newMask.set(markerMask(it)) }

            assertEquals(CaptureStatus.Ok, result.get().status)
            assertEquals(listOf(newMask.get()), result.get().maskSnapshot?.masks)
            val jpeg = requireNotNull(BitmapFactory.decodeByteArray(result.get().jpeg, 0, result.get().jpeg.size))
            assertColorNear(MASK_FILL, jpeg.at(newMask.get().centerX, newMask.get().centerY))
            assertColorNear(WindowCaptureActivity.FILL, jpeg.at(oldMask.get().centerX, oldMask.get().centerY))
        }
    }

    @Test
    fun secureWindowIsNeverCopied() {
        assumeTrue(Build.VERSION.SDK_INT >= CaptureRuntime.MIN_WINDOW_API)
        ActivityScenario.launch(WindowCaptureActivity::class.java).use { scenario ->
            val (window, width, height) = presentedWindow(scenario)
            scenario.onActivity { it.window.addFlags(WindowManager.LayoutParams.FLAG_SECURE) }

            val result = capture(window, CaptureRequest(2, width, height, force = true))

            assertEquals(CaptureStatus.SecureWindow, result.status)
            assertNull(result.coverage)
            assertEquals(0, result.jpeg.size)
        }
    }

    /**
     * Drives the real committed-frame wait (two animation frames on API 26-28,
     * the frame-commit callback on 29+) end to end. Emulators rarely hit the
     * stale-buffer race itself; `WindowTargetTest` covers that ordering.
     */
    @Test
    fun captureRightAfterClearingSecureCopiesTheNewFrame() {
        assumeTrue(Build.VERSION.SDK_INT >= CaptureRuntime.MIN_WINDOW_API)
        ActivityScenario.launch(WindowCaptureActivity::class.java).use { scenario ->
            val (window, width, height) = presentedWindow(scenario)
            val secureDrawn = CountDownLatch(1)
            scenario.onActivity {
                it.window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
                it.fill(SECRET)
                it.afterTwoFrames { secureDrawn.countDown() }
            }
            assertTrue(secureDrawn.await(5, TimeUnit.SECONDS))
            scenario.onActivity {
                it.window.clearFlags(WindowManager.LayoutParams.FLAG_SECURE)
                it.fill(WindowCaptureActivity.FILL)
            }

            val result = capture(window, CaptureRequest(4, width, height, force = true))

            assertEquals(CaptureStatus.Ok, result.status)
            val jpeg = requireNotNull(BitmapFactory.decodeByteArray(result.jpeg, 0, result.jpeg.size))
            assertColorNear(WindowCaptureActivity.FILL, jpeg.at(0.5, 0.5))
        }
    }

    @Test
    fun windowCaptureBelowApi26IsUnsupported() {
        assumeTrue(Build.VERSION.SDK_INT < CaptureRuntime.MIN_WINDOW_API)
        ActivityScenario.launch(WindowCaptureActivity::class.java).use { scenario ->
            val (window, width, height) = presentedWindow(scenario)

            val result = capture(window, CaptureRequest(3, width, height, force = true))

            assertEquals(CaptureStatus.UnsupportedApi, result.status)
        }
    }

    /** The window and half its decor size, once it has been presented. */
    private fun presentedWindow(scenario: ActivityScenario<WindowCaptureActivity>): Triple<Window, Int, Int> {
        val activity = AtomicReference<WindowCaptureActivity>()
        scenario.onActivity { activity.set(it) }
        assertTrue(activity.get().presented.await(5, TimeUnit.SECONDS))
        val out = AtomicReference<Triple<Window, Int, Int>>()
        scenario.onActivity {
            val decor = it.window.decorView
            out.set(Triple(it.window, decor.width / 2, decor.height / 2))
        }
        return out.get()
    }

    private fun capture(window: Window, request: CaptureRequest): CaptureResult {
        val latch = CountDownLatch(1)
        val result = AtomicReference<CaptureResult>()
        runtime.capture(window, request) {
            result.set(it)
            latch.countDown()
        }
        assertTrue(latch.await(5, TimeUnit.SECONDS))
        return result.get()
    }

    /** Main thread. The marker's bounds normalized to the decor view. */
    private fun markerMask(activity: WindowCaptureActivity): NormalizedMask {
        val decor = activity.window.decorView
        val marker = activity.marker
        val location = IntArray(2)
        marker.getLocationInWindow(location)
        return NormalizedMask(
            x = location[0].toDouble() / decor.width,
            y = location[1].toDouble() / decor.height,
            width = marker.width.toDouble() / decor.width,
            height = marker.height.toDouble() / decor.height,
        )
    }

    private val NormalizedMask.centerX: Double
        get() = x + width / 2

    private val NormalizedMask.centerY: Double
        get() = y + height / 2

    private fun Bitmap.at(x: Double, y: Double): Int = getPixel((x * width).toInt(), (y * height).toInt())

    private fun assertColorNear(expected: Int, actual: Int) {
        val near =
            abs(Color.red(expected) - Color.red(actual)) <= TOLERANCE &&
                abs(Color.green(expected) - Color.green(actual)) <= TOLERANCE &&
                abs(Color.blue(expected) - Color.blue(actual)) <= TOLERANCE
        assertTrue("expected ~#%06x, got #%06x".format(expected and 0xFFFFFF, actual and 0xFFFFFF), near)
    }

    private fun sha256Hex(bytes: ByteArray): String =
        MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }

    private companion object {
        /** Centred on (0.5, 0.5) of the decor view. */
        val MASK = NormalizedMask(x = 0.25, y = 0.375, width = 0.5, height = 0.25)

        /** `native-capture-contracts.md` Masks: (0x1a, 0x1a, 0x1a). */
        val MASK_FILL: Int = Color.rgb(0x1a, 0x1a, 0x1a)

        /** Painted only while the window is `FLAG_SECURE`. */
        val SECRET: Int = Color.rgb(0xC0, 0x20, 0x20)

        /** JPEG q80 drift on flat regions far from any edge. */
        const val TOLERANCE = 24
    }
}
