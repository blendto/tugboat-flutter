package com.tugboat.android.views.identity

import android.content.res.Resources
import android.view.View
import com.tugboat.android.R

/** Resource entry names for view ids, or null when an id has none. */
internal fun interface ResourceNames {
    fun entryName(view: View): String?
}

/**
 * Entry names from [Resources.getResourceEntryName]. Resource entry names
 * survive normal release builds. When resource-name obfuscation is on, ids
 * are dropped from identity rather than used (design note 6.1): the probe is
 * this library's own `tugboat_view_tag` id, whose entry name an obfuscator
 * would rename too. Generated ids (`View.generateViewId`) have no entry.
 */
internal class AndroidResourceNames(private val resources: Resources) : ResourceNames {
    private val cache = HashMap<Int, String?>()

    /** False when resource names look obfuscated: no view id is used. */
    val enabled: Boolean = entry(R.id.tugboat_view_tag) == PROBE_NAME

    override fun entryName(view: View): String? {
        val id = view.id
        if (!enabled || id == View.NO_ID || !isResourceId(id)) return null
        return cache.getOrPut(id) { entry(id) }
    }

    private fun entry(id: Int): String? =
        try {
            resources.getResourceEntryName(id)
        } catch (_: Resources.NotFoundException) {
            null
        }

    private companion object {
        const val PROBE_NAME = "tugboat_view_tag"

        /** Resource ids carry a nonzero package byte; generated ids do not. */
        fun isResourceId(id: Int) = (id ushr 24) != 0
    }
}
