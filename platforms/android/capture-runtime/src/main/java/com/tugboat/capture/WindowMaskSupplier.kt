package com.tugboat.capture

import android.view.Window

/**
 * Computes the masks for the frame a window capture is about to copy.
 *
 * Called **on the main thread**, inside the same task that requests the copy:
 * after the runtime waited for a freshly committed frame and re-checked
 * `FLAG_SECURE`, and immediately before `PixelCopy.request`. The masks then
 * describe the layout of the frame being copied, not an earlier one (a list
 * that scrolled, an animation, an IME resize in between would otherwise move
 * text outside its mask).
 *
 * If it throws, the whole frame is masked. It must not block.
 */
fun interface WindowMaskSupplier {
    fun masksFor(window: Window): MaskSnapshot
}

/**
 * What a capture masked, and how the host described the frame. The runtime
 * reads [masks] and [wholeFrame]; [structureSignature] and [coverage] are
 * the host's, passed back in `CaptureResult.maskSnapshot`.
 */
data class MaskSnapshot(
    /** Normalized to the window's decor view. */
    val masks: List<NormalizedMask>,
    /** Mask the whole frame (the host could not describe it with confidence). */
    val wholeFrame: Boolean = false,
    /**
     * The host's opaque visible-structure token. The dHash skip uses
     * `CaptureRequest.lastDHash` only when the request's
     * `lastStructureSignature` is empty or equals this.
     */
    val structureSignature: String = "",
    val coverage: MaskCoverage? = null,
) {
    companion object {
        /** Everything masked: the fallback when a supplier fails. */
        val WHOLE_FRAME = MaskSnapshot(
            masks = listOf(NormalizedMask(0.0, 0.0, 1.0, 1.0)),
            wholeFrame = true,
            coverage = MaskCoverage(MaskCoverageMode.WholeFrame),
        )
    }
}

/** How precisely a frame's masks follow its content, and why not more. */
data class MaskCoverage(
    val mode: MaskCoverageMode,
    /** Reason names from the host's closed vocabulary. */
    val reasons: List<String> = emptyList(),
)

enum class MaskCoverageMode {
    /** Every maskable element has its own rectangle. */
    Precise,

    /** A toolkit host view is masked whole. */
    WholeHost,

    /** The whole frame is masked. */
    WholeFrame,
}
