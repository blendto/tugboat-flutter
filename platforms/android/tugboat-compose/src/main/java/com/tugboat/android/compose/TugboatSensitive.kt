package com.tugboat.android.compose

import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.SemanticsPropertyKey
import androidx.compose.ui.semantics.semantics

/**
 * Marks this node's bounds as always masked in screenshots, at every mask
 * level, including under [ComposeMasking.SemanticsBestEffort]. Pixels are
 * redacted; taps and fingerprints are unchanged. The flag survives semantics
 * merging when a child is folded into a parent.
 */
fun Modifier.tugboatSensitive(): Modifier =
    this.semantics { this[TugboatSensitiveKey] = true }

/** The semantics key behind [tugboatSensitive]; `true` wins when merging. */
internal val TugboatSensitiveKey = SemanticsPropertyKey<Boolean>(
    name = "TugboatSensitive",
    mergePolicy = { parent, child -> (parent == true) || (child == true) },
)
