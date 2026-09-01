package com.tugboat.capture.internal

internal object MaskMapper {
    fun toPixelRects(
        masks: List<com.tugboat.capture.NormalizedMask>,
        width: Int,
        height: Int,
    ): IntArray {
        if (width <= 0 || height <= 0) return IntArray(0)
        val packed = ArrayList<Int>(masks.size * 4)
        for (mask in masks) {
            if (mask.width <= 0.0 || mask.height <= 0.0) continue
            val left = kotlin.math.floor(mask.x * width).toInt().coerceIn(0, width)
            val top = kotlin.math.floor(mask.y * height).toInt().coerceIn(0, height)
            val right =
                kotlin.math.ceil((mask.x + mask.width) * width).toInt().coerceIn(0, width)
            val bottom =
                kotlin.math.ceil((mask.y + mask.height) * height).toInt().coerceIn(0, height)
            if (right <= left || bottom <= top) continue
            packed.add(left)
            packed.add(top)
            packed.add(right)
            packed.add(bottom)
        }
        return packed.toIntArray()
    }
}
