package com.tugboat.capture.internal

import android.app.Activity
import android.graphics.Bitmap
import android.os.Handler
import android.os.Looper
import android.view.PixelCopy
import android.view.View
import android.view.Window
import android.view.WindowManager
import com.tugboat.capture.CaptureStatus
import com.tugboat.capture.MaskSnapshot
import com.tugboat.capture.WindowMaskSupplier
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import org.robolectric.annotation.ConscryptMode
import org.robolectric.annotation.GraphicsMode
import java.time.Duration
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference

@RunWith(RobolectricTestRunner::class)
@ConscryptMode(ConscryptMode.Mode.OFF)
@Config(sdk = [26])
@GraphicsMode(GraphicsMode.Mode.LEGACY)
class WindowTargetTest {
    /** Holds the frame continuation until the test commits a frame. */
    private class HeldFrame : FrameWaiter {
        var decor: View? = null
        private var pending: Runnable? = null

        override fun afterNextFrame(
            decor: View,
            action: Runnable,
        ) {
            this.decor = decor
            pending = action
        }

        fun commit() {
            val action = checkNotNull(pending) { "no frame was awaited" }
            pending = null
            action.run()
        }
    }

    private class RecordingCopy(
        private val onRequest: (PixelCopy.OnPixelCopyFinishedListener) -> Unit = {},
    ) : WindowCopy {
        var requests = 0

        override fun request(
            window: Window,
            destination: Bitmap,
            listener: PixelCopy.OnPixelCopyFinishedListener,
            handler: Handler,
        ) {
            requests++
            onRequest(listener)
        }
    }

    private val frame = HeldFrame()
    private val copy = RecordingCopy { it.onPixelCopyFinished(PixelCopy.SUCCESS) }
    private val finished = mutableListOf<CaptureStatus>()

    /** Records when masks are taken, relative to copy requests. */
    private val events = mutableListOf<String>()
    private val masks = WindowMaskSupplier {
        events += "masks@${copy.requests}"
        MaskSnapshot(emptyList(), structureSignature = "now")
    }

    private fun window(): Window = Robolectric.buildActivity(Activity::class.java).setup().get().window

    private fun issue(
        window: Window,
        isCurrent: () -> Boolean = { true },
        windowCopy: WindowCopy = copy,
    ) = WindowTarget(window, masks, frame, windowCopy).issue(bitmap(), Handler(Looper.getMainLooper()), isCurrent) {
        finished += it
    }

    private fun bitmap() = Bitmap.createBitmap(4, 4, Bitmap.Config.ARGB_8888)

    @Test
    fun windowIsAvailableOnlyOnceItsDecorIsAttached() {
        val controller = Robolectric.buildActivity(Activity::class.java).create()
        val target = WindowTarget(controller.get().window)
        assertFalse(target.isAvailable())

        controller.start().resume().visible()
        assertTrue(target.isAvailable())
    }

    @Test
    fun unattachedWindowIsSurfaceUnavailableAtIssue() {
        issue(Robolectric.buildActivity(Activity::class.java).create().get().window)

        assertEquals(listOf(CaptureStatus.SurfaceUnavailable), finished)
        assertNull(frame.decor)
    }

    @Test
    fun secureFlagIsReadFromWindowAttributes() {
        val window = window()
        assertFalse(window.isSecure())
        window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
        assertTrue(window.isSecure())
    }

    @Test
    fun secureWindowAtIssueIsNeverCopiedAndWaitsForNoFrame() {
        val window = window()
        window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)

        issue(window)

        assertEquals(listOf(CaptureStatus.SecureWindow), finished)
        assertNull(frame.decor)
        assertEquals(0, copy.requests)
    }

    @Test
    fun clearedSecureFlagIsCopiedOnlyAfterTheNextCommittedFrame() {
        val window = window()
        window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
        window.clearFlags(WindowManager.LayoutParams.FLAG_SECURE)

        issue(window)

        assertSame(window.decorView, frame.decor)
        assertEquals(0, copy.requests)
        assertTrue(finished.isEmpty())

        frame.commit()

        assertEquals(1, copy.requests)
        assertEquals(listOf(CaptureStatus.Ok), finished)
    }

    @Test
    fun masksAreTakenAfterTheCommittedFrameAndRightBeforeTheCopy() {
        val target = WindowTarget(window(), masks, frame, copy)
        target.issue(bitmap(), Handler(Looper.getMainLooper()), { true }) { finished += it }
        assertTrue("nothing is taken before the frame", events.isEmpty())
        assertNull(target.snapshot)

        frame.commit()

        assertEquals("taken once, before the single copy request", listOf("masks@0"), events)
        assertEquals(1, copy.requests)
        assertEquals("now", target.snapshot?.structureSignature)
    }

    @Test
    fun noMasksAreTakenWhenTheFrameTurnsSecure() {
        val window = window()
        issue(window)
        window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)

        frame.commit()

        assertTrue(events.isEmpty())
    }

    @Test
    fun aThrowingSupplierStillCopiesWithTheWholeFrameMasked() {
        val target = WindowTarget(window(), { throw IllegalStateException("walk") }, frame, copy)
        target.issue(bitmap(), Handler(Looper.getMainLooper()), { true }) { finished += it }

        frame.commit()

        assertEquals(MaskSnapshot.WHOLE_FRAME, target.snapshot)
        assertEquals(listOf(CaptureStatus.Ok), finished)
    }

    @Test
    fun secureFlagSetWhileWaitingForTheFrameIsHonoured() {
        val window = window()
        issue(window)
        window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)

        frame.commit()

        assertEquals(listOf(CaptureStatus.SecureWindow), finished)
        assertEquals(0, copy.requests)
    }

    @Test
    fun requestThatIsNoLongerCurrentAtTheFrameIsNotCopied() {
        val current = AtomicBoolean(true)
        issue(window(), isCurrent = current::get)
        current.set(false)

        frame.commit()

        assertEquals(listOf(CaptureStatus.Cancelled), finished)
        assertEquals(0, copy.requests)
    }

    @Test
    fun pixelCopyCodesAndRejectionMapToStatuses() {
        val window = window()
        issue(window, windowCopy = RecordingCopy { it.onPixelCopyFinished(PixelCopy.ERROR_TIMEOUT) })
        frame.commit()
        issue(window, windowCopy = RecordingCopy { it.onPixelCopyFinished(PixelCopy.ERROR_SOURCE_NO_DATA) })
        frame.commit()
        issue(window, windowCopy = RecordingCopy { throw IllegalArgumentException("no surface") })
        frame.commit()

        assertEquals(
            listOf(CaptureStatus.Timeout, CaptureStatus.PixelCopyFailed, CaptureStatus.PixelCopyFailed),
            finished,
        )
    }

    @Test
    @Config(sdk = [28])
    fun committedFrameWaiterRunsOnlyAfterLaterFrames() {
        val decor = window().decorView
        val ran = AtomicBoolean(false)

        CommittedFrameWaiter.afterNextFrame(decor) { ran.set(true) }
        assertFalse(ran.get())

        shadowOf(Looper.getMainLooper()).idleFor(Duration.ofSeconds(1))
        assertTrue(ran.get())
    }

    @Test
    fun secureFlagSetAfterResolveIsHonouredOnTheMainThread() {
        val window = window()
        val resolved = WindowSource(window, masks).resolve() as SourceResolution.Ready
        window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
        val bitmap = bitmap()

        val outcome = copyOnCaptureThread(resolved.target, bitmap, timeoutMs = 5_000) { true }

        assertEquals(CaptureStatus.SecureWindow, outcome.status)
        assertTrue(outcome.callerOwnsDestination)
        assertFalse(bitmap.isRecycled)
    }

    @Test
    fun timeoutWhileWaitingForTheFrameHandsTheBitmapToTheLateCallback() {
        val current = AtomicBoolean(true)
        val bitmap = bitmap()

        val outcome =
            copyOnCaptureThread(WindowTarget(window(), frames = frame, copy = copy), bitmap, timeoutMs = 50, isCurrent = current::get)

        assertEquals(CaptureStatus.Timeout, outcome.status)
        assertFalse(outcome.callerOwnsDestination)
        assertFalse(bitmap.isRecycled)

        current.set(false)
        frame.commit()

        assertEquals(0, copy.requests)
        assertTrue(bitmap.isRecycled)
    }

    private fun copyOnCaptureThread(
        target: PixelCopyTarget,
        bitmap: Bitmap,
        timeoutMs: Long,
        isCurrent: () -> Boolean,
    ): PixelCopyOutcome {
        val outcome = AtomicReference<PixelCopyOutcome>()
        val captureThread = Thread { outcome.set(PixelCopyCapture.copy(target, bitmap, timeoutMs, isCurrent)) }
        captureThread.start()
        while (captureThread.isAlive) {
            shadowOf(Looper.getMainLooper()).idle()
            captureThread.join(10)
        }
        return outcome.get()
    }
}
