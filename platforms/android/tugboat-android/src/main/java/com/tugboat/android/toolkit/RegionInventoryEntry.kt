package com.tugboat.android.toolkit

/** A scene inventory element's tier: actionable, or content (an image or large text). */
@TugboatToolkitApi
enum class InventoryTier {
    Interactive,
    Content,
}

/**
 * One element a region contributes to a scene inventory: a [target] as
 * [ToolkitRegion.targetAt] would answer for it (the Views adapter anchors
 * both the same way, so the fingerprints agree) and its [tier].
 */
@TugboatToolkitApi
class RegionInventoryEntry(val target: RegionHit.Target, val tier: InventoryTier)

/** [ToolkitRegion.inventory]'s answer: at most the requested [entries], and how many the region found in all. */
@TugboatToolkitApi
class RegionInventory(val entries: List<RegionInventoryEntry>, val total: Int) {
    companion object {
        val EMPTY = RegionInventory(emptyList(), 0)
    }
}
