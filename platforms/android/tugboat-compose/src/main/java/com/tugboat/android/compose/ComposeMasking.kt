package com.tugboat.android.compose

/**
 * How Compose content is masked under `allTextAndMedia`. Pass it to
 * [TugboatCompose.install].
 */
enum class ComposeMasking {
    /**
     * The default: every Compose host (`ComposeView`, `setContent`) is masked
     * over its whole bounds. Nothing Compose draws can leak.
     */
    WholeHost,

    /**
     * Masks only what the semantics tree describes: text, editable text,
     * images with `Role.Image`, nodes with a content description, nodes
     * marked with [tugboatSensitive] and every node below them, and
     * `AndroidView` interop bounds. Identity, scroll, and focus are the same
     * in both modes.
     *
     * **Residual leak, accepted by choosing this mode.** Content without
     * semantics is not masked and is captured as drawn:
     * - `Image`, `Icon`, and `AsyncImage` with `contentDescription = null`;
     * - `drawText`, and anything drawn on a `Canvas`, in `drawBehind` /
     *   `drawWithContent`, or by `Modifier.paint`.
     *
     * Use it only for screens where such content shows nothing private, or
     * mark the private parts with [tugboatSensitive], which masks a node's
     * bounds whether or not it has semantics of its own.
     * Outside the tested Compose UI range it is ignored and hosts are masked
     * whole.
     */
    SemanticsBestEffort,
}
