package com.tugboat.capture.internal

import android.app.Activity
import android.graphics.Bitmap
import android.os.Handler
import android.os.Looper
import android.view.WindowManager
import com.tugboat.capture.CaptureStatus
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import org.robolectric.annotation.ConscryptMode
import org.robolectric.annotation.GraphicsMode
import java.util.concurrent.atomic.AtomicReference

@RunWith(RobolectricTestRunner::class)
@ConscryptMode(ConscryptMode.Mode.OFF)
@Config(sdk = [26])
@GraphicsMode(GraphicsMode.Mode.LEGACY)
class WindowTargetTest {
    @Test
    fun windowIsAvailableOnlyOnceItsDecorIsAttached() {
        val controller = Robolectric.buildActivity(Activity::class.java).create()
        val target = WindowTarget(controller.get().window)
        assertFalse(target.isAvailable())

        controller.start().resume().visible()
        assertTrue(target.isAvailable())
    }

    @Test
    fun secureFlagIsReadFromWindowAttributes() {
        val window = Robolectric.buildActivity(Activity::class.java).setup().get().window
        assertFalse(window.isSecure())
        window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
        assertTrue(window.isSecure())
    }

    @Test
    fun secureWindowIsNeverIssuedToPixelCopy() {
        val window = Robolectric.buildActivity(Activity::class.java).setup().get().window
        window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
        var callbacks = 0

        val issued =
            WindowTarget(window).issue(
                Bitmap.createBitmap(4, 4, Bitmap.Config.ARGB_8888),
                { callbacks++ },
                Handler(Looper.getMainLooper()),
            )

        assertEquals(CaptureStatus.SecureWindow, issued)
        assertEquals(0, callbacks)
    }

    @Test
    fun secureFlagSetAfterResolveIsHonouredOnTheMainThread() {
        val window = Robolectric.buildActivity(Activity::class.java).setup().get().window
        val resolved = WindowSource(window).resolve() as SourceResolution.Ready
        window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
        val bitmap = Bitmap.createBitmap(4, 4, Bitmap.Config.ARGB_8888)
        val outcome = AtomicReference<PixelCopyOutcome>()

        val captureThread =
            Thread { outcome.set(PixelCopyCapture.copy(resolved.target, bitmap, 5_000) { true }) }
        captureThread.start()
        while (captureThread.isAlive) {
            shadowOf(Looper.getMainLooper()).idle()
            captureThread.join(10)
        }

        assertEquals(CaptureStatus.SecureWindow, outcome.get().status)
        assertTrue(outcome.get().callerOwnsDestination)
        assertFalse(bitmap.isRecycled)
    }
}
