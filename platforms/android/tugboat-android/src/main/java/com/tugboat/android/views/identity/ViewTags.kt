package com.tugboat.android.views.identity

import android.view.View
import com.tugboat.android.R

/**
 * Tugboat's view tags. The public `View.tugboatTag` extension (SDK slice)
 * writes [alias]; capture overlays the SDK adds are marked [sdkOwned] so
 * identity and masks skip them.
 */
internal object ViewTags {
    fun alias(view: View): String? = (view.getTag(R.id.tugboat_view_tag) as? String)?.takeIf { it.isNotEmpty() }

    fun setAlias(view: View, alias: String?) = view.setTag(R.id.tugboat_view_tag, alias)

    fun isSdkOwned(view: View): Boolean = view.getTag(R.id.tugboat_sdk_owned) == true

    fun markSdkOwned(view: View) = view.setTag(R.id.tugboat_sdk_owned, true)
}
