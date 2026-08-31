package com.tugboat.capture.internal

import com.tugboat.capture.NormalizedMask
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Test

class MaskMapperTest {
    @Test
    fun dropsEmptyAndNonPositive() {
        val packed =
            MaskMapper.toPixelRects(
                listOf(
                    NormalizedMask(0.0, 0.0, 0.0, 1.0),
                    NormalizedMask(0.0, 0.0, 1.0, -0.1),
                ),
                100,
                100,
            )
        assertEquals(0, packed.size)
    }

    @Test
    fun privacyExpandsWithFloorCeil() {
        val packed =
            MaskMapper.toPixelRects(listOf(NormalizedMask(0.25, 0.25, 0.5, 0.5)), 8, 8)
        assertArrayEquals(intArrayOf(2, 2, 6, 6), packed)
    }

    @Test
    fun clipsToBounds() {
        val packed =
            MaskMapper.toPixelRects(listOf(NormalizedMask(-0.1, -0.1, 2.0, 2.0)), 10, 10)
        assertArrayEquals(intArrayOf(0, 0, 10, 10), packed)
    }

    @Test
    fun ignoresFullyOutsideAfterClip() {
        val packed =
            MaskMapper.toPixelRects(listOf(NormalizedMask(2.0, 2.0, 0.1, 0.1)), 10, 10)
        assertEquals(0, packed.size)
    }
}
