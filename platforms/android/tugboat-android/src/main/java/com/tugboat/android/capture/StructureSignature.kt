package com.tugboat.android.capture

import com.tugboat.android.views.mask.WindowMaskResult

/**
 * The visible structure a frame was captured under, for perceptual
 * coalescing (stateful-engine.md 8.2, "dHash baseline"): a 64-bit FNV-1a hash
 * of the decor size and the mask rectangles. Two frames with the same
 * signature mask the same regions, so a dHash within distance 2 means the
 * unmasked pixels look the same; a moved, added, or removed text or image
 * view changes it and the frame is encoded instead of coalesced. Opaque to
 * the engine, which only compares it.
 */
internal object StructureSignature {
    private const val OFFSET_BASIS = -0x340d631b7bdddcdbL // 0xcbf29ce484222325
    private const val PRIME = 0x100000001b3L

    /** Mask coordinates are quantized so float noise does not change the signature. */
    private const val QUANTUM = 10_000.0

    fun of(geometry: CaptureGeometry, masks: WindowMaskResult): String {
        var hash = OFFSET_BASIS
        fun mix(value: Long) {
            for (shift in 0 until Long.SIZE_BITS step Byte.SIZE_BITS) {
                hash = (hash xor ((value ushr shift) and 0xff)) * PRIME
            }
        }
        mix(geometry.widthPx.toLong())
        mix(geometry.heightPx.toLong())
        for (rect in masks.rects) {
            mix(quantize(rect.x))
            mix(quantize(rect.y))
            mix(quantize(rect.width))
            mix(quantize(rect.height))
        }
        return java.lang.Long.toHexString(hash)
    }

    private fun quantize(value: Double): Long = Math.round(value * QUANTUM)
}
