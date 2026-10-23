package com.tugboat.android.views.overlay

import com.tugboat.android.toolkit.MaskCoverageReason
import com.tugboat.android.views.mask.MaskCoverage
import com.tugboat.android.views.mask.WindowMaskResult

internal fun WindowMaskResult.withOverlayWindowReason(): WindowMaskResult {
    if (MaskCoverageReason.OverlayWindow in coverage.reasons) return this
    return copy(
        coverage = MaskCoverage(coverage.mode, coverage.reasons + MaskCoverageReason.OverlayWindow),
    )
}
