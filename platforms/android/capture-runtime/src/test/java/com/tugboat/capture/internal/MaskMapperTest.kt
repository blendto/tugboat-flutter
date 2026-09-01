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

    @Test
    fun mapsLandscapeAndPortraitTheSameNormalizedRect() {
        val mask = listOf(NormalizedMask(0.0, 0.0, 0.25, 0.25))
        assertArrayEquals(intArrayOf(0, 0, 40, 20), MaskMapper.toPixelRects(mask, 160, 80))
        assertArrayEquals(intArrayOf(0, 0, 20, 40), MaskMapper.toPixelRects(mask, 80, 160))
    }

    @Test
    fun originQuarterMaskCoversAtLeastOnePixelOnTypicalSizes() {
        val mask = listOf(NormalizedMask(0.0, 0.0, 0.25, 0.25))
        for (size in intArrayOf(40, 80, 120, 270, 293, 323)) {
            val packed = MaskMapper.toPixelRects(mask, size, size)
            assertEquals(4, packed.size)
            assertEquals(0, packed[0])
            assertEquals(0, packed[1])
            val expectedRight = kotlin.math.ceil(0.25 * size).toInt().coerceAtMost(size)
            assertEquals(expectedRight, packed[2])
            assertEquals(expectedRight, packed[3])
            assertEquals(true, packed[2] > packed[0])
        }
    }
}
