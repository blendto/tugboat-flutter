package com.tugboat.android.views.identity

import org.json.JSONArray
import org.json.JSONObject

/**
 * A resolved target, serialized as the engine's `targetAnchor`
 * (conformance/README.md) plus `toolkit` (design note 6): `view`, or the
 * region's toolkit (`compose`) for a region target or host. The toolkit is
 * never a hash input. Visible text and content descriptions are
 * never part of it.
 */
internal data class TargetAnchor(
    val widgetType: String,
    val role: String?,
    val fingerprint: String,
    val confidence: Confidence,
    val tagFingerprint: String?,
    val routeKey: String,
    val tag: String?,
    val canonicalPath: String,
    val relativePosition: String?,
    val enabled: Boolean?,
    val actions: List<String>,
    val toolkit: String = TOOLKIT,
) {
    fun toJson(): JSONObject {
        val json = JSONObject()
            .put("schemaVersion", IdentityHash.FINGERPRINT_SCHEMA_VERSION)
            .put("widgetType", widgetType)
        role?.let { json.put("role", it) }
        if (fingerprint.isNotEmpty()) {
            json.put("fingerprint", fingerprint).put("fingerprintConfidence", confidence.wire)
        }
        tagFingerprint?.let { json.put("tagFingerprint", it) }
        json.put("fingerprintParts", fingerprintParts())
        if (canonicalPath.isNotEmpty()) json.put("canonicalPath", canonicalPath)
        relativePosition?.let { json.put("relativePosition", it) }
        enabled?.let { json.put("enabled", it) }
        if (actions.isNotEmpty()) json.put("actions", JSONArray(actions))
        return json.put("toolkit", toolkit)
    }

    /** Small serialized evidence, not the hash input (the path is). */
    private fun fingerprintParts(): JSONObject {
        val parts = JSONObject()
            .put("schemaVersion", IdentityHash.FINGERPRINT_SCHEMA_VERSION.toString())
            .put("routeKey", routeKey)
        tag?.let { parts.put("tag", it) }
        return parts
    }

    companion object {
        const val TOOLKIT = "view"
    }
}
