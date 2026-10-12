package com.tugboat.android.views.mask

import android.view.View
import android.widget.Checkable

/**
 * The visible structure of a window as an opaque token (stateful-engine.md
 * 8.2, "dHash baseline"), built during the mask walk: a 64-bit FNV-1a hash
 * over the decor size and, per visited view in walk order, its class, id,
 * visibility, and checked / selected / activated state, plus every mask
 * rectangle. Close to Flutter's structure signature: a toggled switch, a
 * newly selected tab, or a moved text view changes it, so the engine does not
 * coalesce such a frame into an earlier one that looks alike at dHash
 * resolution. Visible text never enters it.
 */
internal class StructureHasher(widthPx: Int, heightPx: Int) {
    private var hash = OFFSET_BASIS

    init {
        mix(widthPx.toLong())
        mix(heightPx.toLong())
    }

    fun addView(view: View) {
        mix(view.javaClass.name.hashCode().toLong())
        mix(view.id.toLong())
        mix(view.visibility.toLong())
        mix(stateBits(view))
    }

    fun addMask(rect: MaskRect) {
        mix(quantize(rect.x))
        mix(quantize(rect.y))
        mix(quantize(rect.width))
        mix(quantize(rect.height))
    }

    fun value(): String = java.lang.Long.toHexString(hash)

    private fun stateBits(view: View): Long {
        var bits = 0L
        if ((view as? Checkable)?.isChecked == true) bits = bits or 1L
        if (view.isSelected) bits = bits or 2L
        if (view.isActivated) bits = bits or 4L
        return bits
    }

    private fun mix(value: Long) {
        for (shift in 0 until Long.SIZE_BITS step Byte.SIZE_BITS) {
            hash = (hash xor ((value ushr shift) and 0xff)) * PRIME
        }
    }

    private companion object {
        const val OFFSET_BASIS = -0x340d631b7bdddcdbL // 0xcbf29ce484222325
        const val PRIME = 0x100000001b3L

        /** Mask coordinates are quantized so float noise does not change the signature. */
        const val QUANTUM = 10_000.0

        fun quantize(value: Double): Long = Math.round(value * QUANTUM)
    }
}
