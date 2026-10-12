package com.tugboat.android.views.mask

/**
 * One mask rectangle normalized to the window's decor view, the rule
 * `capture-runtime`'s `capture(Window, …)` applies to
 * `com.tugboat.capture.NormalizedMask` (x, y, width, height in [0, 1]).
 */
internal data class MaskRect(val x: Double, val y: Double, val width: Double, val height: Double) {
    companion object {
        val FULL_FRAME = MaskRect(0.0, 0.0, 1.0, 1.0)
    }
}

/** Why a view is masked (native SDK note 2.1). */
internal enum class MaskSource {
    Text,
    Media,

    /** Content the SDK cannot see into: masked over its whole bounds and never walked. */
    FailClosed,
}

/** How precisely the masks follow the frame's content (the engine's `maskCoverage.mode`). */
internal enum class MaskMode(val wire: String) {
    /** Every maskable view has its own rectangle. */
    Precise("precise"),

    /** A toolkit host (a Compose view without its adapter) is masked whole. */
    WholeHost("wholeHost"),

    /** The whole frame is masked. */
    WholeFrame("wholeFrame"),
}

/** The Views reasons from the engine's closed `maskCoverage.reasons` set. */
internal enum class MaskReason(val wire: String) {
    /** Whole frame: no attached decor view. */
    NoDecor("noDecor"),

    /** Whole frame: the decor view has no size. */
    NoWindowSize("noWindowSize"),

    /** Whole frame: the walk failed. */
    WalkExhausted("walkExhausted"),

    /** Whole frame: a legacy view animation or a layout transition is running ([AnimationProbe]). */
    Animating("animating"),

    /** Whole host: a Compose view, masked over its bounds until the Compose adapter describes it. */
    ComposeDefault("composeDefault"),

    /** Informational: a `WebView` is masked over its bounds. */
    WebView("webView"),

    /** Informational: a `SurfaceView` / `TextureView` is masked over its bounds. */
    SurfaceLayer("surfaceLayer"),
}

internal data class MaskCoverage(val mode: MaskMode, val reasons: List<MaskReason> = emptyList())

/**
 * The masks for one capture, how they cover the frame, and the visible
 * structure they were computed from ([structureSignature], opaque).
 */
internal data class WindowMaskResult(
    val rects: List<MaskRect>,
    val coverage: MaskCoverage,
    val structureSignature: String,
) {
    /** True when the whole frame is masked. */
    val failClosed: Boolean
        get() = coverage.mode == MaskMode.WholeFrame

    companion object {
        fun wholeFrame(reason: MaskReason, structureSignature: String = "wholeFrame:${reason.wire}") =
            WindowMaskResult(listOf(MaskRect.FULL_FRAME), MaskCoverage(MaskMode.WholeFrame, listOf(reason)), structureSignature)
    }
}
