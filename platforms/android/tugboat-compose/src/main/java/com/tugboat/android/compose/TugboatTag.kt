package com.tugboat.android.compose

import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.SemanticsPropertyKey
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.testTag

/**
 * Gives this element a developer alias for Tugboat identity, like
 * `View.tugboatTag` for Views. The alias yields a high-confidence
 * `tagFingerprint` and does not change the structural fingerprint. Prefer it
 * over `testTag`, which Tugboat also reads. An empty [tag] is ignored.
 *
 * Inside a merged element (a button, a list row), a tag on a child is
 * attributed to the merged element unless the element has its own.
 *
 * [accessibility] `true` also sets `testTag(tag)` on the same node, so one id
 * serves Tugboat and UI tests (`onNodeWithTag`). Identity is the same either
 * way. Unlike the alias, a `testTag` does not merge up: tag the control
 * itself, not a child of it. Test tools that read the accessibility tree
 * (Maestro, Appium, UiAutomator) see a `testTag` as a resource-id only under
 * an ancestor with `Modifier.semantics { testTagsAsResourceId = true }`,
 * which Tugboat does not set.
 *
 * It is off by default because a node keeps one `testTag`, the first in the
 * modifier chain: `Modifier.tugboatTag("pay", accessibility = true).testTag("app")`
 * replaces the app's own `testTag` with `pay`, and
 * `.testTag("app").tugboatTag("pay", accessibility = true)` keeps `app`.
 * Tugboat's alias is [tag] in both orders.
 */
@JvmOverloads
fun Modifier.tugboatTag(tag: String, accessibility: Boolean = false): Modifier =
    this.semantics {
        this[TugboatTagKey] = tag
        if (accessibility && tag.isNotEmpty()) testTag = tag
    }

/** The semantics key behind [tugboatTag]; the parent's value wins when merging. */
internal val TugboatTagKey = SemanticsPropertyKey<String>(
    name = "TugboatTag",
    mergePolicy = { parent, child -> parent ?: child },
)
