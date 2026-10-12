package com.tugboat.android.toolkit

import android.graphics.RectF

/** Masks for one region host under `allTextAndMedia`; the variant is the coverage mode that applied. */
@TugboatToolkitApi
sealed class RegionMasks {
    /** Precise masks: [rects] in host pixels. [reasons] notes what they include (for example [MaskCoverageReason.Interop]). */
    class Rects(val rects: List<RectF>, val reasons: Set<MaskCoverageReason> = emptySet()) : RegionMasks()

    /** Mask the host's whole bounds, for [reason]. */
    class WholeHost(val reason: MaskCoverageReason) : RegionMasks()

    /** Mask the whole captured frame, for [reason]: the region cannot say where its content is. */
    class WholeFrame(val reason: MaskCoverageReason) : RegionMasks()
}

/**
 * Why a capture's masks are coarser than precise, or what precise masks
 * include: a closed vocabulary the host reports per frame (`capture.result`)
 * and the engine turns into a `capture_diagnostic`.
 */
@TugboatToolkitApi
enum class MaskCoverageReason(val wire: String) {
    /** Compose hosts are masked whole by default (`ComposeMasking.WholeHost`). */
    ComposeDefault("composeDefault"),

    /** The Compose UI version is outside the tested range: masked whole, the opt-in ignored. */
    ComposeVersionUnverified("composeVersionUnverified"),

    /** The Compose semantics owner could not be read. */
    ComposeOwnerUnavailable("composeOwnerUnavailable"),

    /** Interop Views inside a region are masked over their whole bounds. */
    Interop("interop"),

    /** A region failed or was asked off the main thread. */
    RegionUnreadable("regionUnreadable"),

    /** The View tree could not be read. */
    TreeUnreadable("treeUnreadable"),

    /** Motion that layout bounds do not describe is running. */
    Animating("animating"),
}
