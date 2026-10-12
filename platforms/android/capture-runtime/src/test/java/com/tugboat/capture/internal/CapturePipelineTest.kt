package com.tugboat.capture.internal

import android.app.Activity
import android.graphics.Bitmap
import android.view.WindowManager
import android.widget.FrameLayout
import com.tugboat.capture.CaptureCoverage
import com.tugboat.capture.CaptureRequest
import com.tugboat.capture.CaptureResult
import com.tugboat.capture.CaptureStatus
import com.tugboat.capture.NormalizedMask
import com.tugboat.capture.RenderMode
import io.flutter.embedding.android.FlutterSurfaceView
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.ConscryptMode
import org.robolectric.annotation.GraphicsMode
import java.security.MessageDigest

@RunWith(RobolectricTestRunner::class)
@ConscryptMode(ConscryptMode.Mode.OFF)
@Config(sdk = [26])
@GraphicsMode(GraphicsMode.Mode.LEGACY)
class CapturePipelineTest {
    private val request =
        CaptureRequest(
            requestId = 7,
            pixelWidth = 8,
            pixelHeight = 8,
            force = false,
            lastDHash = "previous",
            masks = listOf(NormalizedMask(0.25, 0.25, 0.5, 0.5)),
        )

    private class RecordingCopier(
        private val status: CaptureStatus = CaptureStatus.Ok,
    ) : FrameCopier {
        val targets = mutableListOf<PixelCopyTarget>()

        override fun copy(
            target: PixelCopyTarget,
            destination: Bitmap,
            timeoutMs: Long,
            isCurrent: () -> Boolean,
        ): PixelCopyOutcome {
            targets += target
            return PixelCopyOutcome(status)
        }
    }

    private class RecordingCore(
        private val status: Int = 0,
    ) : FrameCore {
        val calls = mutableListOf<Pair<IntArray, String>>()

        override fun process(
            bitmap: Bitmap,
            masksPacked: IntArray,
            lastDHash: String,
            force: Boolean,
        ): NativeProcessResult {
            calls += masksPacked to lastDHash
            return NativeProcessResult(status, DHASH, maskFillMicros = 3, dHashMicros = 4)
        }
    }

    private fun activity(): Activity = Robolectric.buildActivity(Activity::class.java).setup().get()

    private fun flutterSource(activity: Activity): FlutterSurfaceSource {
        val root = FrameLayout(activity)
        root.addView(FlutterSurfaceView(activity))
        return FlutterSurfaceSource(root)
    }

    private fun CapturePipeline.run(source: CaptureSource): CaptureResult = capture(source, request) { true }

    @Test
    fun bothSourcesShareOnePipelineAndDifferOnlyInSourceFields() {
        val activity = activity()
        val copier = RecordingCopier()
        val core = RecordingCore()
        val pipeline = CapturePipeline(timeoutMs = 100, copier = copier, core = core)

        val surface = pipeline.run(flutterSource(activity))
        val window = pipeline.run(WindowSource(activity.window))

        assertTrue(copier.targets[0] is SurfaceViewTarget)
        assertTrue(copier.targets[1] is WindowTarget)
        assertEquals(2, core.calls.size)
        for ((masks, lastDHash) in core.calls) {
            assertArrayEquals(intArrayOf(2, 2, 6, 6), masks)
            assertEquals("previous", lastDHash)
        }

        assertEquals(CaptureCoverage.EngineSurface, surface.coverage)
        assertEquals(RenderMode.SurfaceView, surface.renderMode)
        assertEquals(CaptureCoverage.WindowComposite, window.coverage)
        assertEquals(RenderMode.Unknown, window.renderMode)
        for (result in listOf(surface, window)) {
            assertEquals(CaptureStatus.Ok, result.status)
            assertEquals(7L, result.requestId)
            assertEquals(8, result.width)
            assertEquals(8, result.height)
            assertEquals(DHASH, result.dHash)
            assertTrue(result.jpeg.isNotEmpty())
            assertEquals(sha256Hex(result.jpeg), result.contentHash)
            assertEquals(3L, result.timings.maskFillMicros)
            assertEquals(4L, result.timings.dHashMicros)
            assertEquals(0L, result.timings.pixelReadbackMicros)
        }
        assertEquals(surface.contentHash, window.contentHash)
    }

    @Test
    fun windowSkipReportsWindowCompositeWithoutJpeg() {
        val pipeline =
            CapturePipeline(timeoutMs = 100, copier = RecordingCopier(), core = RecordingCore(status = 1))

        val result = pipeline.run(WindowSource(activity().window))

        assertEquals(CaptureStatus.SkippedByDHash, result.status)
        assertEquals(CaptureCoverage.WindowComposite, result.coverage)
        assertEquals(0, result.jpeg.size)
        assertEquals("", result.contentHash)
        assertEquals(0L, result.timings.jpegMicros)
    }

    @Test
    fun secureWindowIsRejectedBeforeAnyCopy() {
        val activity = activity()
        activity.window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
        val copier = RecordingCopier()
        val core = RecordingCore()

        val result = CapturePipeline(timeoutMs = 100, copier = copier, core = core).run(WindowSource(activity.window))

        assertEquals(CaptureStatus.SecureWindow, result.status)
        assertNull(result.coverage)
        assertEquals(0, result.jpeg.size)
        assertEquals(0, result.width)
        assertTrue(copier.targets.isEmpty())
        assertTrue(core.calls.isEmpty())
    }

    @Test
    fun copyRefusalIsFramelessAndSkipsTheCore() {
        val core = RecordingCore()
        val pipeline =
            CapturePipeline(timeoutMs = 100, copier = RecordingCopier(CaptureStatus.SecureWindow), core = core)

        val result = pipeline.run(WindowSource(activity().window))

        assertEquals(CaptureStatus.SecureWindow, result.status)
        assertNull(result.coverage)
        assertEquals(0, result.jpeg.size)
        assertTrue(core.calls.isEmpty())
    }

    @Test
    fun coreFailureIsProcessingFailedForWindows() {
        val pipeline =
            CapturePipeline(timeoutMs = 100, copier = RecordingCopier()) { _, _, _, _ ->
                throw UnsatisfiedLinkError("no core")
            }

        val result = pipeline.run(WindowSource(activity().window))

        assertEquals(CaptureStatus.ProcessingFailed, result.status)
        assertNull(result.coverage)
    }

    @Test
    fun cancelledAfterCopyIsFrameless() {
        val pipeline = CapturePipeline(timeoutMs = 100, copier = RecordingCopier(), core = RecordingCore())

        val result = pipeline.capture(WindowSource(activity().window), request) { false }

        assertEquals(CaptureStatus.Cancelled, result.status)
        assertNull(result.coverage)
    }

    private fun sha256Hex(bytes: ByteArray): String =
        MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }

    private companion object {
        val DHASH = "01".repeat(32)
    }
}
