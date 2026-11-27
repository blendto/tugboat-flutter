package com.tugboat.capture.internal

import com.tugboat.capture.CaptureRequest
import com.tugboat.capture.MaskSnapshot
import com.tugboat.capture.NormalizedMask

/**
 * The masks and dHash baseline a copied frame is processed with. A
 * [MaskingTarget] (window capture) supplies them from the main thread at copy
 * time; other targets use the request's. A masking target that copied
 * without a snapshot is masked whole (fail closed).
 */
internal class AppliedMasks(
    val rects: List<NormalizedMask>,
    val lastDHash: String,
    val snapshot: MaskSnapshot?,
    val computeMicros: Long,
) {
    companion object {
        fun of(target: PixelCopyTarget, request: CaptureRequest): AppliedMasks {
            val masking = target as? MaskingTarget ?: return AppliedMasks(request.masks, request.lastDHash, null, 0)
            val snapshot = masking.snapshot ?: MaskSnapshot.WHOLE_FRAME
            val rects = if (snapshot.wholeFrame) MaskSnapshot.WHOLE_FRAME.masks else snapshot.masks
            val expected = request.lastStructureSignature
            val baseline = if (expected.isEmpty() || expected == snapshot.structureSignature) request.lastDHash else ""
            return AppliedMasks(rects, baseline, snapshot, masking.maskComputeMicros)
        }
    }
}
