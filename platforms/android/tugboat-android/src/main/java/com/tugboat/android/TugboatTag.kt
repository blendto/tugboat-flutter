@file:JvmName("TugboatViews")

package com.tugboat.android

import android.view.View
import com.tugboat.android.views.identity.ViewTags

/**
 * The developer alias for this view's identity: a high-confidence
 * `tagFingerprint` that survives layout changes. It is transparent to the
 * structural fingerprint and never contains user content. Null or empty
 * removes it.
 */
var View.tugboatTag: String?
    get() = ViewTags.alias(this)
    set(value) = ViewTags.setAlias(this, value?.takeIf { it.isNotEmpty() })
