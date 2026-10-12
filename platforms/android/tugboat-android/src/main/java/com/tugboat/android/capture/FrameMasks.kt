package com.tugboat.android.capture

import android.view.Window
import com.tugboat.android.views.mask.MaskMode
import com.tugboat.android.toolkit.MaskCoverageReason
import com.tugboat.android.views.mask.WindowMaskResult
import com.tugboat.capture.MaskCoverage
import com.tugboat.capture.MaskCoverageMode
import com.tugboat.capture.MaskSnapshot
import com.tugboat.capture.NormalizedMask
import com.tugboat.capture.WindowMaskSupplier

/**
 * The mask supplier for one capture. `capture-runtime` calls it on the main
 * thread right before `PixelCopy.request`, so the masks, the motion check,
 * the structure signature, and the boundary all describe the copied frame.
 * It keeps what it computed for the `capture.result`.
 */
internal class FrameMasks(private val compute: (Window) -> WindowMaskResult) : WindowMaskSupplier {
    @Volatile
    private var taken: Taken? = null

    /** Null until the runtime reached the copy. */
    val result: WindowMaskResult?
        get() = taken?.masks

    val geometry: CaptureGeometry?
        get() = taken?.geometry

    /** What the frame was masked with: the computed masks, or the whole frame when none were taken. */
    val applied: WindowMaskResult
        get() = result ?: WindowMaskResult.wholeFrame(MaskCoverageReason.WalkExhausted)

    override fun masksFor(window: Window): MaskSnapshot {
        val geometry = CaptureGeometry.of(window.peekDecorView())
        val masks = compute(window)
        taken = Taken(masks, geometry)
        return MaskSnapshot(
            masks = masks.rects.map { NormalizedMask(it.x, it.y, it.width, it.height) },
            wholeFrame = masks.failClosed,
            structureSignature = masks.structureSignature,
            coverage = MaskCoverage(mode(masks.coverage.mode), masks.coverage.reasons.map { it.wire }.sorted()),
        )
    }

    private class Taken(val masks: WindowMaskResult, val geometry: CaptureGeometry?)

    private fun mode(mode: MaskMode): MaskCoverageMode =
        when (mode) {
            MaskMode.Precise -> MaskCoverageMode.Precise
            MaskMode.WholeHost -> MaskCoverageMode.WholeHost
            MaskMode.WholeFrame -> MaskCoverageMode.WholeFrame
        }
}
