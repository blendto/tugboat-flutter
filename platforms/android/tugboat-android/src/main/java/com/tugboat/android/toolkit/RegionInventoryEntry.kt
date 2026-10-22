package com.tugboat.android.toolkit

import android.graphics.RectF

/** One element the region contributes to a scene inventory (host-local bounds). */
@TugboatToolkitApi
data class RegionInventoryEntry(
    val pathSegments: List<String>,
    val widgetType: String,
    val role: String?,
    val actions: List<String>,
    val enabled: Boolean?,
    val tag: String?,
    val inListItem: Boolean,
    val bounds: RectF,
    val tier: String,
    val structuralFingerprint: String?,
)
