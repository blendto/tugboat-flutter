package com.tugboat.android.toolkit

import android.graphics.RectF
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner

/** The one rect rule both mask walks use under `tugboatSensitive`. */
@RunWith(RobolectricTestRunner::class)
class SensitiveRectsTest {
    private val parent = RectF(0f, 0f, 100f, 100f)
    private val inside = RectF(10f, 10f, 50f, 50f)
    private val outside = RectF(10f, 150f, 50f, 190f)

    @Test
    fun unmarkedWalksAddExactlyTheirSourcesAndPassNoCover() {
        val source = SensitiveRects.step(marked = false, isSource = true, bounds = inside, cover = null)
        assertTrue(source.addsRect)
        assertNull(source.childCover)
        assertFalse(SensitiveRects.step(marked = false, isSource = false, bounds = inside, cover = null).addsRect)
    }

    @Test
    fun aMarkedNodeAddsItsBoundsAndCoversItsChildren() {
        val step = SensitiveRects.step(marked = true, isSource = false, bounds = parent, cover = null)
        assertTrue(step.addsRect)
        assertSame(parent, step.childCover)
    }

    @Test
    fun aMarkedNodeInsideItsCoverAddsNothingAndKeepsTheCover() {
        for (isSource in listOf(false, true)) {
            val step = SensitiveRects.step(marked = true, isSource = isSource, bounds = inside, cover = parent)
            assertFalse("already covered, source=$isSource", step.addsRect)
            assertSame(parent, step.childCover)
        }
    }

    @Test
    fun aMarkedNodeOutsideItsCoverAddsItsOwnRect() {
        val step = SensitiveRects.step(marked = true, isSource = false, bounds = outside, cover = parent)
        assertTrue(step.addsRect)
        assertSame(outside, step.childCover)
    }

    @Test
    fun aMarkedNodeWithoutGeometryAddsNothingAndLetsItsChildrenAddTheirs() {
        val step = SensitiveRects.step(marked = true, isSource = true, bounds = null, cover = null)
        assertFalse(step.addsRect)
        assertNull(step.childCover)
    }
}
