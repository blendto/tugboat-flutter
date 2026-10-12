package com.tugboat.android.capture

import org.json.JSONObject

/**
 * Encodes [CaptureAnswer]s as `capture.result` inputs.
 *
 * Both backend fields are always [NATIVE_BACKEND]: the collector's
 * `frameMetadata[].requestedBackend` / `resolvedBackend` are a closed enum
 * (`flutterRepaintBoundary` | `nativeCpuExperimental`), and the native SDKs
 * capture through the native CPU pixel runtime. A new backend name would 400
 * every frame upload (decisions log).
 */
internal object CaptureResultJson {
    const val NATIVE_BACKEND = "nativeCpuExperimental"

    /** One day, the engine's bound on every duration. */
    private const val MAX_MICROS = 86_400_000_000L

    fun encode(answer: CaptureAnswer): String {
        val input = JSONObject().put("requestId", answer.requestId)
        when (answer) {
            is CaptureAnswer.Captured -> {
                input.put("outcome", "captured")
                input.put("frame", frame(answer.frame))
                input.put("boundaryRect", answer.boundaryRect.toJson())
                input.put("timings", timings(answer.timings))
            }
            is CaptureAnswer.Failed -> {
                input.put("outcome", "failed")
                input.put("failure", answer.failure.wire)
                answer.timings?.let { input.put("timings", timings(it)) }
            }
            is CaptureAnswer.Cancelled -> input.put("outcome", "cancelled")
        }
        return input.toString()
    }

    private fun frame(frame: CapturedFrame): JSONObject {
        val json = JSONObject()
            .put("handle", frame.handle)
            .put("width", frame.width)
            .put("height", frame.height)
            .put("contentHash", frame.contentHash)
            .put("masked", frame.masked)
            .put("byteLength", frame.byteLength)
            .put("captureMicros", clamp(frame.captureMicros))
            .put("requestedBackend", NATIVE_BACKEND)
            .put("resolvedBackend", NATIVE_BACKEND)
        frame.dHash?.takeIf { it.isNotEmpty() }?.let { json.put("dHash", it) }
        frame.structureSignature?.let { json.put("structureSignature", it) }
        return json
    }

    private fun timings(timings: CaptureTimingsMicros): JSONObject =
        JSONObject()
            .put("frameWaitMicros", clamp(timings.frameWaitMicros))
            .put("readbackMicros", clamp(timings.readbackMicros))
            .put("maskMicros", clamp(timings.maskMicros))
            .put("encodeMicros", clamp(timings.encodeMicros))

    private fun clamp(micros: Long): Long = micros.coerceIn(0, MAX_MICROS)
}
