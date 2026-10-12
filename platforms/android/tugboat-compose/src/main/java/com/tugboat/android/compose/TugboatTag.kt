package com.tugboat.android.compose

import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.SemanticsPropertyKey
import androidx.compose.ui.semantics.semantics

/**
 * Gives this element a developer alias for Tugboat identity, like
 * `View.tugboatTag` for Views. The alias yields a high-confidence
 * `tagFingerprint` and does not change the structural fingerprint. Prefer it
 * over `testTag`, which Tugboat also reads. An empty [tag] is ignored.
 *
 * Inside a merged element (a button, a list row), a tag on a child is
 * attributed to the merged element unless the element has its own.
 */
fun Modifier.tugboatTag(tag: String): Modifier = this.semantics { this[TugboatTagKey] = tag }

/** The semantics key behind [tugboatTag]; the parent's value wins when merging. */
internal val TugboatTagKey = SemanticsPropertyKey<String>(
    name = "TugboatTag",
    mergePolicy = { parent, child -> parent ?: child },
)
