package com.tugboat.android.views.inventory

import org.json.JSONArray
import org.json.JSONObject

/**
 * Every rule `decode_scene_inventory_fact` (core/session-engine
 * `scene_inventory.cpp`) applies, plus the bounds the engine would otherwise
 * truncate silently. The device test `SceneInventoryEngineTest` sends the
 * same builder output through the real engine.
 */
internal object SceneInventoryFactContract {
    private val FACT_KEYS = setOf("routeKey", "elements", "scrollKey", "totalElements")
    private val ELEMENT_KEYS = setOf(
        "fingerprint",
        "canonicalPath",
        "widgetType",
        "role",
        "actions",
        "enabled",
        "boundsNorm",
        "tier",
        "aliases",
    )
    private val BOUNDS_KEYS = setOf("left", "top", "width", "height")
    private val TIERS = setOf("interactive", "content")
    private const val BOUNDS_EPSILON = 1e-9
    private const val MAX_STRING_UTF16 = 1024
    private const val MAX_LIST = 16

    fun assertFact(json: JSONObject) {
        json.keys().forEach { key -> check(key in FACT_KEYS) { "unknown fact key $key" } }
        optString(json, "routeKey")
        optString(json, "scrollKey")
        val elements = json.get("elements") as? JSONArray ?: error("elements must be an array")
        if (json.has("totalElements")) {
            val total = json.get("totalElements")
            check(total is Int || total is Long) { "totalElements must be an integer" }
            check((total as Number).toLong() >= elements.length()) { "totalElements below elements.length" }
        }
        for (i in 0 until elements.length()) assertElement(elements.get(i) as? JSONObject ?: error("element $i is not an object"))
    }

    private fun assertElement(element: JSONObject) {
        element.keys().forEach { key -> check(key in ELEMENT_KEYS) { "unknown element key $key" } }
        val fingerprint = requireString(element, "fingerprint")
        check(fingerprint.isNotEmpty()) { "fingerprint must not be empty" }
        requireString(element, "canonicalPath")
        optString(element, "widgetType")
        optString(element, "role")
        stringList(element, "actions")
        if (element.has("enabled")) check(element.get("enabled") is Boolean) { "enabled must be a boolean" }
        check(requireString(element, "tier") in TIERS) { "tier must be interactive or content" }
        stringList(element, "aliases")
        assertBounds(element.get("boundsNorm") as? JSONObject ?: error("boundsNorm must be an object"))
    }

    private fun assertBounds(bounds: JSONObject) {
        check(bounds.keys().asSequence().toSet() == BOUNDS_KEYS) { "boundsNorm keys must be $BOUNDS_KEYS" }
        val (left, top, width, height) = BOUNDS_KEYS.toList().map { (bounds.get(it) as? Number)?.toDouble() ?: error("$it must be a number") }
        check(left in 0.0..1.0 && top in 0.0..1.0) { "left and top must be in [0, 1]" }
        check(width > 0 && height > 0) { "width and height must be positive" }
        check(left + width <= 1 + BOUNDS_EPSILON && top + height <= 1 + BOUNDS_EPSILON) { "bounds past the window" }
    }

    private fun requireString(json: JSONObject, key: String): String {
        val value = json.opt(key) as? String ?: error("$key must be a string")
        check(value.length <= MAX_STRING_UTF16) { "$key longer than $MAX_STRING_UTF16 UTF-16 units" }
        return value
    }

    private fun optString(json: JSONObject, key: String) {
        if (json.has(key)) requireString(json, key)
    }

    private fun stringList(json: JSONObject, key: String) {
        if (!json.has(key)) return
        val array = json.get(key) as? JSONArray ?: error("$key must be an array")
        check(array.length() <= MAX_LIST) { "more than $MAX_LIST $key" }
        for (i in 0 until array.length()) {
            val value = array.get(i) as? String ?: error("$key[$i] must be a string")
            check(value.length <= MAX_STRING_UTF16) { "$key[$i] longer than $MAX_STRING_UTF16 UTF-16 units" }
        }
    }
}
