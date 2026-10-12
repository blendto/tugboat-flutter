package com.tugboat.android.capture

import android.app.Activity
import android.app.Application
import android.view.View
import com.tugboat.android.views.mask.MaskRect
import com.tugboat.android.views.mask.WindowMaskResult
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment

/** `surface` facts, the foreground window, and the structure signature. */
@RunWith(RobolectricTestRunner::class)
class SurfaceTest {
    private val posted = ArrayList<JSONObject>()
    private val reporter = SurfaceReporter { posted += JSONObject(it) }

    @Test
    fun theFirstRectKeepsGenerationZeroAndEachChangeAdvancesIt() {
        reporter.observe(BoundaryRect(0.0, 0.0, 400.0, 800.0))
        reporter.observe(BoundaryRect(0.0, 0.0, 400.0, 800.0))
        reporter.observe(BoundaryRect(0.0, 0.0, 800.0, 400.0))
        reporter.observe(BoundaryRect(0.0, 0.0, 400.0, 800.0))

        assertEquals(listOf(0L, 1L, 2L), posted.map { it.getLong("generation") })
        assertEquals(800.0, posted[1].getJSONObject("boundaryRect").getDouble("width"), 0.0)
    }

    @Test
    fun theResumedActivityIsTheCaptureWindowAndItsLayoutIsReported() {
        val application = RuntimeEnvironment.getApplication() as Application
        val rects = ArrayList<BoundaryRect>()
        val foreground = ForegroundWindow(application) { rects += it }
        foreground.start()

        val controller = Robolectric.buildActivity(Activity::class.java).setup()
        val activity = controller.get()
        assertSame(activity.window, foreground.window)

        val decor = activity.window.decorView
        decor.measure(exactly(600), exactly(300))
        decor.layout(0, 0, 600, 300)
        assertEquals(BoundaryRect(0.0, 0.0, 600.0, 300.0), rects.last())

        controller.pause().stop().destroy()
        assertNull(foreground.window)
        foreground.stop()
    }

    @Test
    fun structureSignaturesFollowGeometryAndMasks() {
        val geometry = CaptureGeometry(1080, 2400, 2.75f)
        val masks = WindowMaskResult(listOf(MaskRect(0.1, 0.2, 0.3, 0.4)), failClosed = false)
        val same = StructureSignature.of(geometry, masks)

        assertEquals(same, StructureSignature.of(geometry, masks.copy(rects = listOf(MaskRect(0.1, 0.2, 0.3, 0.400000001)))))
        assertNotEquals(same, StructureSignature.of(geometry, masks.copy(rects = listOf(MaskRect(0.1, 0.25, 0.3, 0.4)))))
        assertNotEquals(same, StructureSignature.of(CaptureGeometry(2400, 1080, 2.75f), masks))
    }

    @Test
    fun pixelSizeIsThreeQuartersOfADpScaledAndBounded() {
        val geometry = CaptureGeometry(1080, 2400, 2.75f)
        assertEquals(295 to 655, geometry.pixelSize(1.0))
        assertEquals(236 to 524, geometry.pixelSize(0.8))
        assertEquals(1 to 1, CaptureGeometry(1, 1, 0.5f).pixelSize(1.0))
    }

    private fun exactly(px: Int) = View.MeasureSpec.makeMeasureSpec(px, View.MeasureSpec.EXACTLY)
}
