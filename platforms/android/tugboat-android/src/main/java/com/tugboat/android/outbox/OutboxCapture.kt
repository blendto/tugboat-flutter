package com.tugboat.android.outbox

import com.tugboat.android.host.FramePart
import com.tugboat.android.host.HttpBody
import com.tugboat.android.host.HttpRequest
import org.json.JSONArray
import org.json.JSONObject
import java.security.MessageDigest

/** The collector lanes the outbox keeps, with the tag their keys carry. */
internal enum class OutboxLane(val wire: String, val tag: String) {
    LIFECYCLE("lifecycle", "l"),
    EVENTS("events", "e"),
    FRAMES("frames", "f"),
    ;

    companion object {
        fun of(wire: String): OutboxLane? = values().firstOrNull { it.wire == wire }
    }
}

/**
 * One logical unit of an `http.send` the outbox keeps until the collector
 * answers for it: the whole body for the JSON lanes, one frame for
 * `/v1/frames` (chunks re-form on every pass, frames do not).
 */
internal class OutboxCapture(
    val key: String,
    val lane: OutboxLane,
    val path: String,
    val sessionId: String,
    /** JSON lanes: the body as sent. */
    val body: ByteArray? = null,
    /** Frames: `{"sessionId","frameNo","metadata"}`, the multipart fields of a one-frame upload. */
    val fields: String? = null,
    /** Frames: the masked JPEG, resolved on the engine thread at dispatch. */
    val jpeg: ByteArray? = null,
)

/**
 * Keys derived from what the host already sends (W11 design 3.1): the engine
 * has no delivery key. Every function is total: a request whose key cannot
 * be derived yields null and is sent without an entry, as before the outbox.
 */
internal object OutboxKeys {
    const val HEADER = "Tugboat-Delivery-Key"
    const val FRAMES_FIELD_SESSION = "sessionId"
    const val FRAMES_FIELD_NUMBERS = "frameNos"
    const val FRAMES_FIELD_METADATA = "frameMetadata"

    /** The units of [request]; null when any key cannot be derived. [frameBytes] resolves frame handles now. */
    fun capture(request: HttpRequest, frameBytes: (handle: String) -> ByteArray?): List<OutboxCapture>? =
        try {
            when (OutboxLane.of(request.lane)) {
                OutboxLane.LIFECYCLE -> lifecycle(request)?.let(::listOf)
                OutboxLane.EVENTS -> events(request)?.let(::listOf)
                OutboxLane.FRAMES -> frames(request, frameBytes)
                null -> null
            }
        } catch (_: Throwable) {
            null
        }

    /** `<sessionId>/l/<eventType>/<triggeredAt>`: `triggeredAt` is fixed when the entry is queued. */
    private fun lifecycle(request: HttpRequest): OutboxCapture? {
        val text = (request.body as? HttpBody.Json)?.text ?: return null
        val body = JSONObject(text)
        val sessionId = body.nonBlank("sessionId") ?: return null
        val eventType = body.nonBlank("eventType") ?: return null
        val triggeredAt = body.nonBlank("triggeredAt") ?: return null
        val key = "$sessionId/${OutboxLane.LIFECYCLE.tag}/$eventType/$triggeredAt"
        return OutboxCapture(key, OutboxLane.LIFECYCLE, request.path, sessionId, body = text.toByteArray(Charsets.UTF_8))
    }

    /** `<sessionId>/e/<sha256 of the sorted event ids>[:16]`: a retry batch is re-sent with the same events. */
    private fun events(request: HttpRequest): OutboxCapture? {
        val text = (request.body as? HttpBody.Json)?.text ?: return null
        val events = JSONObject(text).getJSONArray("events")
        if (events.length() == 0) return null
        val ids = ArrayList<String>(events.length())
        var sessionId: String? = null
        for (index in 0 until events.length()) {
            val event = events.getJSONObject(index)
            ids += event.nonBlank("id") ?: return null
            val eventSession = event.nonBlank("sessionId") ?: return null
            if (sessionId != null && sessionId != eventSession) return null
            sessionId = eventSession
        }
        val session = sessionId ?: return null
        val digest = sha256Hex(ids.sorted().joinToString("\n")).take(16)
        val key = "$session/${OutboxLane.EVENTS.tag}/$digest"
        return OutboxCapture(key, OutboxLane.EVENTS, request.path, session, body = text.toByteArray(Charsets.UTF_8))
    }

    /** Per frame, `<sessionId>/f/<frameNo>`: from the multipart fields and the `<frameNo>.jpg` filenames. */
    private fun frames(request: HttpRequest, frameBytes: (String) -> ByteArray?): List<OutboxCapture>? {
        val body = request.body as? HttpBody.Multipart ?: return null
        val fields = body.fields.toMap()
        val sessionId = fields[FRAMES_FIELD_SESSION]?.takeIf { it.isNotBlank() } ?: return null
        val numbers = fields[FRAMES_FIELD_NUMBERS]?.split(',') ?: return null
        val metadata = JSONArray(fields[FRAMES_FIELD_METADATA] ?: return null)
        if (numbers.size != body.frames.size || metadata.length() != body.frames.size || numbers.isEmpty()) return null
        return body.frames.mapIndexed { index, part ->
            frame(request.path, sessionId, numbers[index], metadata.getJSONObject(index), part, frameBytes) ?: return null
        }
    }

    private fun frame(
        path: String,
        sessionId: String,
        frameNo: String,
        metadata: JSONObject,
        part: FramePart,
        frameBytes: (String) -> ByteArray?,
    ): OutboxCapture? {
        if (frameNo.isBlank() || part.filename != "$frameNo.jpg") return null
        val jpeg = frameBytes(part.handle) ?: return null
        val fields = JSONObject().put("sessionId", sessionId).put("frameNo", frameNo).put("metadata", metadata)
        val key = "$sessionId/${OutboxLane.FRAMES.tag}/$frameNo"
        return OutboxCapture(key, OutboxLane.FRAMES, path, sessionId, fields = fields.toString(), jpeg = jpeg)
    }

    /** The multipart fields of a one-frame upload, in the engine's order. */
    fun frameFields(fieldsJson: String): List<Pair<String, String>>? =
        try {
            val fields = JSONObject(fieldsJson)
            listOf(
                FRAMES_FIELD_SESSION to fields.getString("sessionId"),
                FRAMES_FIELD_NUMBERS to fields.getString("frameNo"),
                FRAMES_FIELD_METADATA to JSONArray().put(fields.getJSONObject("metadata")).toString(),
            )
        } catch (_: Throwable) {
            null
        }

    fun sha256Hex(text: String): String = hex(MessageDigest.getInstance("SHA-256").digest(text.toByteArray(Charsets.UTF_8)))

    fun hex(bytes: ByteArray): String = bytes.joinToString("") { "%02x".format(it.toInt() and 0xFF) }

    private fun JSONObject.nonBlank(name: String): String? =
        if (has(name) && !isNull(name)) optString(name).takeIf { it.isNotBlank() } else null
}
