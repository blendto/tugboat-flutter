@file:JvmName("TugboatViews")

package com.tugboat.android

import android.view.View
import com.tugboat.android.views.identity.ViewTags

/**
 * The developer alias for this view's identity: a high-confidence
 * `tagFingerprint` that survives layout changes. It is transparent to the
 * structural fingerprint and never contains user content. Null or empty
 * removes it.
 *
 * It has no accessibility option, unlike Compose's `Modifier.tugboatTag`:
 * test tools (Maestro, Appium, UiAutomator) read a view's resource-id from
 * its `android:id`, whose entry name Tugboat already uses as the alias when
 * the view has no `tugboatTag` and no other view under its route root has
 * the same id. Tugboat installs no `AccessibilityDelegate`, so the app's own
 * delegate is never replaced.
 */
var View.tugboatTag: String?
    get() = ViewTags.alias(this)
    set(value) = ViewTags.setAlias(this, value?.takeIf { it.isNotEmpty() })

/**
 * Marks this view and its whole subtree as always masked in screenshots, at
 * every mask level, and returns this view (so `TextView(context).tugboatSensitive()`
 * keeps its type). A subview drawn outside this view's bounds is masked at
 * its own bounds. Only pixels are masked: taps, canonical paths, and
 * fingerprints are the same with or without it.
 *
 * There is no un-mark: a view stays sensitive for its lifetime, including a
 * recycled `RecyclerView` row rebound to other content. That fails safe: it
 * over-masks, never under-masks.
 *
 * From Java, call `TugboatViews.tugboatSensitive(view)`.
 */
fun <T : View> T.tugboatSensitive(): T {
    ViewTags.markSensitive(this)
    return this
}
