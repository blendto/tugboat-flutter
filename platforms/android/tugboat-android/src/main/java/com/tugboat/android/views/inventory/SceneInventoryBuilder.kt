package com.tugboat.android.views.inventory

import android.graphics.RectF
import android.view.View
import android.view.ViewGroup
import android.widget.ImageView
import android.widget.TextView
import com.tugboat.android.toolkit.InventoryTier
import com.tugboat.android.views.identity.AnchorResolver
import com.tugboat.android.views.identity.IdCounts
import com.tugboat.android.views.identity.ResourceNames
import com.tugboat.android.views.identity.RouteResolver
import com.tugboat.android.views.identity.TargetAnchor
import com.tugboat.android.views.identity.ViewGeometry
import com.tugboat.android.views.identity.ViewRules
import com.tugboat.android.views.region.RegionHost
import com.tugboat.android.views.region.Regions
import org.json.JSONArray
import org.json.JSONObject
import java.util.TreeSet

/**
 * Builds `scene.inventory` inputs from a window's decor tree. Main thread
 * only ([SceneInventoryEmitter] checks).
 *
 * Every element is a [TargetAnchor] (the tap anchor of the same view or
 * region target, so the fingerprints agree), its normalized bounds, and a
 * tier. Views are anchored with [AnchorResolver.anchorFor], region targets
 * with `RegionAnchors.anchor`.
 */
internal class SceneInventoryBuilder(
    private val names: ResourceNames,
    private val routes: RouteResolver,
    private val anchors: AnchorResolver,
    /** One per walk, shared by its anchors. A seam for tests, which count the id walks. */
    private val newIdCounts: () -> IdCounts = { IdCounts() },
    /** Told at the start of each walk; a seam for tests. */
    private val onWalk: () -> Unit = {},
) {
    /**
     * The elements of [routeKey] in [decor]: views (and region targets)
     * whose own route key it is. At most [limit] are collected; the rest
     * are only counted. Null when there are none.
     */
    fun build(decor: View, routeKey: String, limit: Int = MAX_ELEMENTS): SceneInventory? {
        if (decor.width <= 0 || decor.height <= 0) return null
        onWalk()
        val walk = InventoryWalk(names, routes, anchors, newIdCounts(), decor, routeKey, limit)
        walk.visit(decor)
        return walk.result()
    }

    companion object {
        /** The engine's `limits.maxSceneInventoryElements` default (change C20). */
        const val MAX_ELEMENTS = 500
    }
}

/** One `scene.inventory` input; [totalElements] counts the candidates the walk found, collected or not (an upper bound). */
internal class SceneInventory(val routeKey: String, val elements: List<InventoryElement>, val totalElements: Int) {
    fun toJson(): JSONObject {
        val array = JSONArray()
        elements.forEach { array.put(it.toJson()) }
        return JSONObject()
            .put("routeKey", routeKey)
            .put("elements", array)
            .put("totalElements", totalElements)
    }
}

/** An anchor, its bounds, and its tier; interactive elements also carry their aliases. */
internal class InventoryElement(val anchor: TargetAnchor, val bounds: NormalizedBounds, val tier: InventoryTier) {
    private val aliases = TreeSet<String>()

    init {
        val tag = anchor.tagFingerprint
        if (tier == InventoryTier.Interactive && tag != null && tag != anchor.fingerprint) aliases += tag
    }

    /** Takes [other]'s aliases: the same fingerprint seen again. */
    fun merge(other: InventoryElement) {
        aliases += other.aliases
    }

    /** Dart `TugboatSceneInventoryEntry.toJson`: content elements carry only identity, bounds, and `role: display`. */
    fun toJson(): JSONObject {
        val json = JSONObject()
            .put("fingerprint", anchor.fingerprint)
            .put("canonicalPath", anchor.canonicalPath)
            .put("widgetType", anchor.widgetType)
        if (tier == InventoryTier.Interactive) {
            anchor.role?.let { json.put("role", it) }
            if (anchor.actions.isNotEmpty()) json.put("actions", JSONArray(anchor.actions))
            anchor.enabled?.let { json.put("enabled", it) }
        } else {
            json.put("role", DISPLAY_ROLE)
        }
        json.put("boundsNorm", bounds.toJson()).put("tier", tier.wire)
        if (aliases.isNotEmpty()) json.put("aliases", JSONArray(aliases.toList()))
        return json
    }

    private companion object {
        const val DISPLAY_ROLE = "display"
    }
}

/** Bounds as fractions of the window, clamped to it. */
internal class NormalizedBounds(val left: Double, val top: Double, val width: Double, val height: Double) {
    val area: Double
        get() = width * height

    fun toJson(): JSONObject = JSONObject().put("left", left).put("top", top).put("width", width).put("height", height)

    companion object {
        /** Null for an empty rectangle, and for NaN (which `JSONObject.put` rejects). */
        fun of(bounds: RectF, windowWidth: Double, windowHeight: Double): NormalizedBounds? {
            val left = (bounds.left / windowWidth).coerceIn(0.0, 1.0)
            val top = (bounds.top / windowHeight).coerceIn(0.0, 1.0)
            val w = (bounds.right / windowWidth).coerceIn(0.0, 1.0) - left
            val h = (bounds.bottom / windowHeight).coerceIn(0.0, 1.0) - top
            if (!(w > 0) || !(h > 0)) return null
            return NormalizedBounds(left, top, w, h)
        }
    }
}

internal val InventoryTier.wire: String
    get() = when (this) {
        InventoryTier.Interactive -> "interactive"
        InventoryTier.Content -> "content"
    }

/**
 * One inventory walk of [decor] for [routeKey], holding the walk state as
 * `MaskWalk` does. Candidates are kept views with the walk's route that are
 * actionable (interactive) or an image or large text (content), and region
 * targets. The first [limit] distinct fingerprints are anchored; later
 * candidates are only counted (no anchor, no path).
 */
private class InventoryWalk(
    private val names: ResourceNames,
    private val routes: RouteResolver,
    private val anchors: AnchorResolver,
    private val ids: IdCounts,
    private val decor: View,
    private val routeKey: String,
    private val limit: Int,
) {
    private val width = decor.width.toDouble()
    private val height = decor.height.toDouble()
    private val elements = LinkedHashMap<String, InventoryElement>()
    private var found = 0

    fun visit(view: View) {
        if (ViewRules.isExcluded(view)) return
        val region = Regions.regionOf(view)
        if (region != null) return region(RegionHost(view, region))
        if (ViewRules.isKept(view, names)) candidate(view)
        if (view is ViewGroup) {
            for (i in 0 until view.childCount) visit(view.getChildAt(i))
        }
    }

    /** Interactive elements first, then content, each in tree order. */
    fun result(): SceneInventory? {
        if (elements.isEmpty()) return null
        val ordered = elements.values.filter { it.tier == InventoryTier.Interactive } +
            elements.values.filter { it.tier == InventoryTier.Content }
        return SceneInventory(routeKey, ordered, maxOf(found, ordered.size))
    }

    private fun candidate(view: View) {
        if (routes.routeFor(view)?.value != routeKey) return
        val bounds = ViewGeometry.boundsIn(decor, view)?.let(::normalize) ?: return
        val tier = tierOf(view, bounds) ?: return
        if (elements.size >= limit) {
            found++
            return
        }
        val anchor = anchors.anchorFor(view, decor, ids) ?: return
        add(InventoryElement(anchor, bounds, tier))
    }

    private fun tierOf(view: View, bounds: NormalizedBounds): InventoryTier? =
        when {
            ViewRules.isActionable(view) -> InventoryTier.Interactive
            view is ImageView || (view is TextView && bounds.area >= LARGE_TEXT_AREA) -> InventoryTier.Content
            else -> null
        }

    private fun region(host: RegionHost) {
        if (routes.routeFor(host.view)?.value != routeKey) return
        val answer = host.inventory((limit - elements.size).coerceAtLeast(0))
        found += (answer.total - answer.entries.size).coerceAtLeast(0)
        for (entry in answer.entries) {
            if (elements.size >= limit) {
                found++
                continue
            }
            val anchor = anchors.regions.anchor(host, entry.target, decor) ?: continue
            val bounds = ViewGeometry.mapRect(decor, host.view, entry.target.bounds)?.let(::normalize) ?: continue
            add(InventoryElement(anchor, bounds, entry.tier))
        }
    }

    /** A repeated fingerprint keeps the first element and merges the aliases. */
    private fun add(element: InventoryElement) {
        val existing = elements[element.anchor.fingerprint]
        if (existing != null) {
            existing.merge(element)
            return
        }
        elements[element.anchor.fingerprint] = element
        found++
    }

    private fun normalize(bounds: RectF): NormalizedBounds? = NormalizedBounds.of(bounds, width, height)

    private companion object {
        /** Dart's large-text threshold, as a fraction of the window area. */
        const val LARGE_TEXT_AREA = 0.02
    }
}
