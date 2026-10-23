package com.tugboat.android.views.inventory

import android.graphics.RectF
import android.os.Looper
import android.util.Log
import android.view.View
import android.view.ViewGroup
import android.widget.ImageView
import android.widget.TextView
import com.tugboat.android.toolkit.RegionInventoryEntry
import com.tugboat.android.views.identity.AnchorResolver
import com.tugboat.android.views.identity.CanonicalPathBuilder
import com.tugboat.android.views.identity.IdentityHash
import com.tugboat.android.views.identity.ResourceNames
import com.tugboat.android.views.identity.RouteResolver
import com.tugboat.android.views.identity.ViewGeometry
import com.tugboat.android.views.identity.ViewRules
import com.tugboat.android.views.region.RegionHost
import com.tugboat.android.views.region.Regions
import org.json.JSONArray
import org.json.JSONObject

/** Builds `scene.inventory` inputs from a window decor tree. Main thread only. */
internal class SceneInventoryBuilder(
    private val names: ResourceNames,
    private val routes: RouteResolver,
    private val paths: CanonicalPathBuilder,
    private val anchors: AnchorResolver,
) {
    private val largeTextArea = 0.02

    fun build(window: android.view.Window, elementLimit: Int = MAX_ELEMENTS): JSONObject? {
        if (Looper.myLooper() != Looper.getMainLooper()) {
            Log.w(TAG, "scene inventory off main thread; dropped")
            return null
        }
        val decor = window.decorView
        val width = decor.width.toDouble()
        val height = decor.height.toDouble()
        if (width <= 0 || height <= 0) return null
        val inventoryRouteKey = routes.routeFor(inventoryRouteView(decor))?.value ?: return null
        val interactive = LinkedHashMap<String, JSONObject>()
        val content = ArrayList<JSONObject>()
        val seenContent = HashSet<String>()
        val remaining = ElementCap(elementLimit)
        collect(
            decor,
            decor,
            decor,
            inventoryRouteKey,
            width,
            height,
            interactive,
            content,
            seenContent,
            remaining,
        )
        if (interactive.isEmpty() && content.isEmpty()) return null
        val elements = JSONArray()
        interactive.values.forEach(elements::put)
        content.forEach(elements::put)
        return JSONObject()
            .put("routeKey", inventoryRouteKey)
            .put("elements", elements)
    }

    private fun inventoryRouteView(decor: View): View {
        val content = decor.findViewById<View>(android.R.id.content) ?: return decor
        val group = content as? ViewGroup
        if (group != null && group.childCount > 0) return group.getChildAt(0)
        return content
    }

    private fun collect(
        decor: View,
        view: View,
        window: View,
        inventoryRouteKey: String,
        width: Double,
        height: Double,
        interactive: LinkedHashMap<String, JSONObject>,
        content: MutableList<JSONObject>,
        seenContent: MutableSet<String>,
        remaining: ElementCap,
    ) {
        if (!remaining.hasCapacity()) return
        if (ViewRules.isExcluded(view)) return
        val region = Regions.regionOf(view)
        if (region != null) {
            regionInventory(
                RegionHost(view, region),
                window,
                inventoryRouteKey,
                width,
                height,
                interactive,
                content,
                seenContent,
                remaining,
            )
            return
        }
        if (ViewRules.isKept(view, names)) {
            val route = routes.routeFor(view)?.value
            if (route == inventoryRouteKey) {
                entryFor(view, decor, window, width, height)?.let { (fp, json) ->
                    when (json.getString("tier")) {
                        InventoryTier.Interactive.wire ->
                            mergeInteractive(interactive, fp, json, remaining)
                        InventoryTier.Content.wire ->
                            if (seenContent.add(fp) && remaining.take()) content += json
                    }
                }
            }
        }
        if (view is ViewGroup) {
            for (i in 0 until view.childCount) {
                collect(
                    decor,
                    view.getChildAt(i),
                    window,
                    inventoryRouteKey,
                    width,
                    height,
                    interactive,
                    content,
                    seenContent,
                    remaining,
                )
                if (!remaining.hasCapacity()) return
            }
        }
    }

    private fun regionInventory(
        host: RegionHost,
        window: View,
        inventoryRouteKey: String,
        width: Double,
        height: Double,
        interactive: LinkedHashMap<String, JSONObject>,
        content: MutableList<JSONObject>,
        seenContent: MutableSet<String>,
        remaining: ElementCap,
    ) {
        val route = routes.routeFor(host.view) ?: return
        if (route.value != inventoryRouteKey) return
        val hostPath = paths.build(route.root, host.view) ?: return
        val prefix = hostPath.value
        for (entry in host.region.inventory(host.view)) {
            if (!remaining.hasCapacity()) return
            val path = (listOf(prefix) + entry.pathSegments).joinToString("/")
            val json = regionEntryJson(route.value, path, entry, window, host.view, width, height) ?: continue
            val fp = json.getString("fingerprint")
            when (json.getString("tier")) {
                InventoryTier.Interactive.wire -> mergeInteractive(interactive, fp, json, remaining)
                InventoryTier.Content.wire ->
                    if (seenContent.add(fp) && remaining.take()) content += json
            }
        }
    }

    private fun entryFor(
        view: View,
        decor: View,
        window: View,
        width: Double,
        height: Double,
    ): Pair<String, JSONObject>? {
        val bounds = ViewGeometry.boundsIn(decor, view) ?: return null
        val norm = normalize(bounds, width, height) ?: return null
        if (ViewRules.isActionable(view)) {
            val anchor = anchors.anchorFor(view, window) ?: return null
            val structural = paths.build(routes.routeFor(view)?.root ?: return null, view)?.value ?: return null
            val structuralFp = IdentityHash.fingerprint(mapOf("routeKey" to anchor.routeKey, "path" to structural))
            val json = JSONObject()
                .put("fingerprint", anchor.fingerprint)
                .put("canonicalPath", anchor.canonicalPath)
                .put("boundsNorm", norm)
                .put("tier", InventoryTier.Interactive.wire)
            anchor.widgetType?.let { json.put("widgetType", it) }
            anchor.role?.let { json.put("role", it) }
            if (anchor.actions.isNotEmpty()) json.put("actions", JSONArray(anchor.actions))
            anchor.enabled?.let { json.put("enabled", it) }
            val aliases = aliasList(structuralFp, anchor.fingerprint, anchor.tagFingerprint)
            if (aliases.isNotEmpty()) json.put("aliases", JSONArray(aliases))
            return anchor.fingerprint to json
        }
        if (view is ImageView || (view is TextView && norm.getDouble("width") * norm.getDouble("height") >= largeTextArea)) {
            val route = routes.routeFor(view) ?: return null
            val path = paths.build(route.root, view)?.value ?: return null
            val fp = IdentityHash.fingerprint(mapOf("routeKey" to route.value, "path" to path))
            val json = JSONObject()
                .put("fingerprint", fp)
                .put("canonicalPath", path)
                .put("widgetType", if (view is ImageView) "ImageView" else "TextView")
                .put("role", "display")
                .put("boundsNorm", norm)
                .put("tier", InventoryTier.Content.wire)
            return fp to json
        }
        return null
    }

    private fun regionEntryJson(
        routeKey: String,
        path: String,
        entry: RegionInventoryEntry,
        window: View,
        host: View,
        width: Double,
        height: Double,
    ): JSONObject? {
        val mapped = ViewGeometry.mapRect(window, host, entry.bounds) ?: return null
        val norm = normalize(mapped, width, height) ?: return null
        val fingerprint = IdentityHash.fingerprint(mapOf("routeKey" to routeKey, "path" to path))
        val json = JSONObject()
            .put("fingerprint", fingerprint)
            .put("canonicalPath", path)
            .put("widgetType", entry.widgetType)
            .put("boundsNorm", norm)
            .put("tier", entry.tier)
        entry.role?.let { json.put("role", it) }
        if (entry.actions.isNotEmpty()) json.put("actions", JSONArray(entry.actions))
        entry.enabled?.let { json.put("enabled", it) }
        val tagFp = entry.tag?.let { IdentityHash.fingerprint(mapOf("routeKey" to routeKey, "tag" to it)) }
        val aliases = aliasList(entry.structuralFingerprint.orEmpty(), fingerprint, tagFp)
        if (aliases.isNotEmpty()) json.put("aliases", JSONArray(aliases))
        return json
    }

    private fun mergeInteractive(
        map: LinkedHashMap<String, JSONObject>,
        fp: String,
        json: JSONObject,
        remaining: ElementCap,
    ) {
        val existing = map[fp]
        if (existing == null) {
            if (!remaining.take()) return
            map[fp] = json
            return
        }
        val merged = JSONArray()
        val aliases = existing.optJSONArray("aliases") ?: JSONArray()
        for (i in 0 until aliases.length()) merged.put(aliases.getString(i))
        json.optJSONArray("aliases")?.let { extra ->
            for (i in 0 until extra.length()) merged.put(extra.getString(i))
        }
        if (merged.length() > 0) existing.put("aliases", merged)
    }

    private fun aliasList(structural: String, primary: String, tagFingerprint: String?): List<String> {
        val out = ArrayList<String>()
        if (structural.isNotEmpty() && structural != primary) out += structural
        if (!tagFingerprint.isNullOrEmpty() && tagFingerprint != primary && tagFingerprint !in out) {
            out += tagFingerprint
        }
        return out.sorted()
    }

    private fun normalize(bounds: RectF, width: Double, height: Double): JSONObject? {
        val left = (bounds.left / width).coerceIn(0.0, 1.0)
        val top = (bounds.top / height).coerceIn(0.0, 1.0)
        val right = (bounds.right / width).coerceIn(0.0, 1.0)
        val bottom = (bounds.bottom / height).coerceIn(0.0, 1.0)
        val w = right - left
        val h = bottom - top
        if (w <= 0 || h <= 0) return null
        return JSONObject()
            .put("left", left)
            .put("top", top)
            .put("width", w)
            .put("height", h)
    }

    private class ElementCap(private var left: Int) {
        fun hasCapacity(): Boolean = left > 0

        fun take(): Boolean {
            if (left <= 0) return false
            left--
            return true
        }
    }

    companion object {
        private const val TAG = "TugboatViews"
        const val MAX_ELEMENTS = 500
    }
}

private enum class InventoryTier(val wire: String) {
    Interactive("interactive"),
    Content("content"),
}
