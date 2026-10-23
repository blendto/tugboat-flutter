package com.tugboat.android.views

import android.app.Activity
import android.app.AlertDialog
import android.os.Bundle
import android.widget.FrameLayout
import com.tugboat.android.host.FakeClock
import com.tugboat.android.toolkit.MaskCoverageReason
import org.junit.After
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.Shadows.shadowOf

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
    fun focusLossWhileResumedAddsOverlayReasonUntilDismissed() {
        val controller = Robolectric.buildActivity(BlankActivity::class.java).setup()
        controller.get().window.callback.onWindowFocusChanged(false)
        shadowOf(android.os.Looper.getMainLooper()).idle()

        assertTrue(
            adapter.masks(controller.get().window).coverage.reasons.contains(MaskCoverageReason.OverlayWindow),
        )

        controller.get().window.callback.onWindowFocusChanged(true)
        shadowOf(android.os.Looper.getMainLooper()).idle()
        assertFalse(
            adapter.masks(controller.get().window).coverage.reasons.contains(MaskCoverageReason.OverlayWindow),
        )
    }

    @Test
    @Config(sdk = [26])
    fun alertDialogShownAddsOverlayReasonViaFocus() {
        val controller = Robolectric.buildActivity(BlankActivity::class.java).setup()
        val dialog = AlertDialog.Builder(controller.get()).setMessage("hello").show()
        shadowOf(android.os.Looper.getMainLooper()).idle()
        controller.get().window.callback.onWindowFocusChanged(false)

        assertTrue(
            adapter.masks(controller.get().window).coverage.reasons.contains(MaskCoverageReason.OverlayWindow),
        )

        dialog.dismiss()
        controller.get().window.callback.onWindowFocusChanged(true)
        shadowOf(android.os.Looper.getMainLooper()).idle()
        assertFalse(
            adapter.masks(controller.get().window).coverage.reasons.contains(MaskCoverageReason.OverlayWindow),
        )
    }

    @Test
    @Config(sdk = [29])
    fun alertDialogShownAddsOverlayReasonViaWindowInspector() {
        val controller = Robolectric.buildActivity(BlankActivity::class.java).setup()
        val dialog = AlertDialog.Builder(controller.get()).setMessage("hello").show()
        shadowOf(android.os.Looper.getMainLooper()).idle()

        assertTrue(
            adapter.masks(controller.get().window).coverage.reasons.contains(MaskCoverageReason.OverlayWindow),
        )

        dialog.dismiss()
        shadowOf(android.os.Looper.getMainLooper()).idle()
        assertFalse(
            adapter.masks(controller.get().window).coverage.reasons.contains(MaskCoverageReason.OverlayWindow),
        )
    }

    class BlankActivity : Activity() {
        override fun onCreate(savedInstanceState: Bundle?) {
            super.onCreate(savedInstanceState)
            setContentView(FrameLayout(this))
        }
    }
}
