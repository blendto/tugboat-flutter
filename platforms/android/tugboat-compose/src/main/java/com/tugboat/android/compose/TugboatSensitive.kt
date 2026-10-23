package com.tugboat.android.compose

import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.SemanticsPropertyKey
import androidx.compose.ui.semantics.semantics

/**
 * Marks this node and every semantics node below it as always masked in
 * screenshots, at every mask level, including under
 * [ComposeMasking.SemanticsBestEffort]: each is masked at its own unclipped
 * bounds, so a child placed outside this node is covered too. Under the
 * default [ComposeMasking.WholeHost] the host is already masked whole.
 *
 * Only pixels are masked. Tap targets, canonical paths, and fingerprints are
 * the same with or without it: identity never reads it. Drawing that has no
 * semantics node of its own and lands outside the marked bounds (a
 * `drawBehind` that overflows, for example) is not covered.
 *
 * Remove the modifier to stop masking; it has no `false` form. Masks read
 * the unmerged semantics tree, so a mark on a child inside a merged element
 * (a button, a list row) masks that child.
 */
fun Modifier.tugboatSensitive(): Modifier =
    this.semantics { this[TugboatSensitiveKey] = true }

/** The semantics key behind [tugboatSensitive]; only `ComposeMasks` reads it. */
internal val TugboatSensitiveKey = SemanticsPropertyKey<Boolean>("TugboatSensitive")
