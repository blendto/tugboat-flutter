package com.tugboat.android.views

import android.app.Activity
import android.app.AlertDialog
import android.os.Bundle
import android.os.Looper
import android.view.View
import android.widget.FrameLayout
import android.widget.PopupWindow
import com.tugboat.android.capture.CaptureAnswer
import com.tugboat.android.capture.CaptureCoordinator
import com.tugboat.android.capture.CapturedFrame
import com.tugboat.android.capture.FakeWindowCapturer
import com.tugboat.android.capture.captureRequest
import com.tugboat.android.host.DHashBaseline
import com.tugboat.android.host.FakeClock
import com.tugboat.android.host.FrameHandleTable
import com.tugboat.android.toolkit.MaskCoverageReason
import com.tugboat.capture.CaptureResult
import com.tugboat.capture.CaptureStatus
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.android.controller.ActivityController
import org.robolectric.annotation.Config

/**
 * Overlay detection as the Views adapter reports it at capture time. Below
 * API 29 only the focus signal exists (Robolectric does not move window
 * focus when a dialog shows, so these tests call it); on API 29+
 * `WindowInspector` sees real dialog and popup roots.
 */
@RunWith(RobolectricTestRunner::class)
class OverlayWindowCaptureTest {
    private val adapter =
        ViewsAdapter(
            application = context as android.app.Application,
            sink = RecordingSink(),
            hostClock = FakeClock(),
            frames = ManualFrames(),
        ).apply { start() }

    @After
    fun stop() = adapter.stop()

    @Test
    @Config(sdk = [26])
    fun focusLossWhileResumedAddsOverlayReasonUntilFocusReturns() {
        val controller = blankActivity()
        focus(controller, false)
        assertTrue(overlayReported(controller))

        focus(controller, true)
        assertFalse(overlayReported(controller))
    }

    @Test
    @Config(sdk = [26])
    fun dialogLeftUpAcrossPauseAndResumeIsStillReported() {
        val controller = blankActivity()
        focus(controller, false)

        // Home and back with the dialog up: focus returns to the dialog, so
        // the activity window gets no focus callback at all.
        controller.pause().stop().restart().start().resume()
        idle()
        assertTrue(overlayReported(controller))
    }

    @Test
    @Config(sdk = [26])
    fun focusLossWhileNotResumedIsIgnored() {
        val controller = blankActivity()
        controller.pause()
        focus(controller, false)

        controller.resume()
        idle()
        assertFalse(overlayReported(controller))
    }

    @Test
    @Config(sdk = [26])
    fun focusLossIsNotReadWhilePaused() {
        val controller = blankActivity()
        focus(controller, false)
        controller.pause()

        assertFalse(overlayReported(controller))
    }

    @Test
    @Config(sdk = [29])
    fun alertDialogShownAddsOverlayReasonViaWindowInspector() {
        val controller = blankActivity()
        val dialog = AlertDialog.Builder(controller.get()).setMessage("hello").show()
        idle()
        assertTrue(overlayReported(controller))

        dialog.dismiss()
        idle()
        assertFalse(overlayReported(controller))
    }

    @Test
    @Config(sdk = [29])
    fun focusablePopupIsReportedAndNonFocusablePopupIsNot() {
        val controller = blankActivity()
        val anchor = controller.get().window.decorView
        val handle = PopupWindow(FrameLayout(controller.get()), 10, 10, false).apply { showAsDropDown(anchor) }
        idle()
        assertFalse("a non-focusable popup (a text handle, a tooltip)", overlayReported(controller))

        val menu = PopupWindow(FrameLayout(controller.get()), 10, 10, true).apply { showAsDropDown(anchor) }
        idle()
        assertTrue("a focusable popup (a spinner, a menu)", overlayReported(controller))
        menu.dismiss()
        handle.dismiss()
    }

    @Test
    @Config(sdk = [29])
    fun dialogLeftUpByAnotherActivityIsNotReported() {
        val first = blankActivity()
        AlertDialog.Builder(first.get()).setMessage("left behind").show()
        idle()
        val second = blankActivity()

        assertTrue(overlayReported(first))
        assertFalse(overlayReported(second))
    }

    @Test
    @Config(sdk = [29])
    fun inMultiWindowModeOnlyTheInspectorCounts() {
        val controller = blankActivity()
        shadowOf(controller.get()).setInMultiWindowMode(true)
        focus(controller, false)
        assertFalse("focus taken by the other app's window", overlayReported(controller))

        val dialog = AlertDialog.Builder(controller.get()).setMessage("hello").show()
        idle()
        assertTrue(overlayReported(controller))
        dialog.dismiss()
    }

    /**
     * Through the capture path, a dialog over an unchanged screen yields a
     * frame whose structure differs from the frame before (so neither the
     * runtime's dHash skip nor the engine's coalescing merges them) and
     * which carries the reason. After dismissal the frame matches the one
     * before the dialog again.
     */
    @Test
    @Config(sdk = [29])
    fun dialogOverAnUnchangedScreenChangesTheCapturedFrameStructure() {
        val controller = blankActivity()
        val capturer = FakeWindowCapturer()
        val answers = ArrayList<CaptureAnswer>()
        val coordinator = CaptureCoordinator(
            mainThread = { task -> task.run(); true },
            window = { controller.get().window },
            awaitWindow = { _, onDone -> onDone() },
            masks = adapter::masks,
            capturer = capturer,
            frames = FrameHandleTable(),
            answer = { answers += it },
        )

        fun capture(id: String, previous: CapturedFrame?): CapturedFrame {
            val baseline = previous?.let { DHashBaseline(it.dHash, it.structureSignature) }
            coordinator.onCaptureRequest(captureRequest(id, force = baseline == null, baseline = baseline))
            val request = capturer.requests.last()
            assertEquals(previous?.structureSignature ?: "", request.lastStructureSignature)
            val snapshot = capturer.copy(request.requestId)
            capturer.calls.last().onComplete(
                CaptureResult(
                    requestId = request.requestId,
                    status = CaptureStatus.Ok,
                    jpeg = byteArrayOf(1),
                    width = 10,
                    height = 20,
                    dHash = "ff",
                    contentHash = "same",
                ),
            )
            val frame = (answers.last() as CaptureAnswer.Captured).frame
            assertEquals(snapshot.structureSignature, frame.structureSignature)
            return frame
        }

        val before = capture("capture-1", null)
        assertFalse(MaskCoverageReason.OverlayWindow in before.maskCoverage.reasons)

        val dialog = AlertDialog.Builder(controller.get()).setMessage("hello").show()
        idle()
        val during = capture("capture-2", before)
        assertNotEquals("the copy-time structure differs from the baseline's", before.structureSignature, during.structureSignature)
        assertTrue(MaskCoverageReason.OverlayWindow in during.maskCoverage.reasons)
        assertEquals("the masks themselves are unchanged", before.maskCoverage.mode, during.maskCoverage.mode)

        dialog.dismiss()
        idle()
        val after = capture("capture-3", during)
        assertNotEquals(during.structureSignature, after.structureSignature)
        assertEquals(before.structureSignature, after.structureSignature)
        assertFalse(MaskCoverageReason.OverlayWindow in after.maskCoverage.reasons)
    }

    private fun blankActivity(): ActivityController<BlankActivity> =
        Robolectric.buildActivity(BlankActivity::class.java).setup().also { idle() }

    private fun focus(controller: ActivityController<*>, hasFocus: Boolean) {
        controller.get().window.callback.onWindowFocusChanged(hasFocus)
        idle()
    }

    private fun overlayReported(controller: ActivityController<*>): Boolean =
        MaskCoverageReason.OverlayWindow in adapter.masks(controller.get().window).coverage.reasons

    private fun idle() = shadowOf(Looper.getMainLooper()).idle()

    class BlankActivity : Activity() {
        override fun onCreate(savedInstanceState: Bundle?) {
            super.onCreate(savedInstanceState)
            setContentView(FrameLayout(this).apply { addView(View(context), FrameLayout.LayoutParams(10, 10)) })
        }
    }
}
