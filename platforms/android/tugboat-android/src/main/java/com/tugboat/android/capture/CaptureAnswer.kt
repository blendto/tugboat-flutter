package com.tugboat.android.capture

import com.tugboat.android.views.mask.MaskCoverage
import org.json.JSONObject

/**
 * One `capture.result` (stateful-engine.md section 8.2). Every
 * `capture.request` gets exactly one, by [requestId].
 */
internal sealed interface CaptureAnswer {
    val requestId: String

    /** Handles the message hands to the engine; the host releases them if it is rejected. */
    val frameHandles: List<String>
        get() = emptyList()

    data class Captured(
        override val requestId: String,
        val frame: CapturedFrame,
        val boundaryRect: BoundaryRect,
        val timings: CaptureTimingsMicros,
    ) : CaptureAnswer {
        override val frameHandles: List<String>
            get() = listOf(frame.handle)
    }

    data class Failed(
        override val requestId: String,
        val failure: CaptureFailure,
        val timings: CaptureTimingsMicros? = null,
    ) : CaptureAnswer

    data class Cancelled(override val requestId: String) : CaptureAnswer

    /** The `capture.result` input object. */
    fun toInputJson(): String = CaptureResultJson.encode(this)
}

/** A frame in the host's handle table, as the engine's `capture.result.frame`. */
internal data class CapturedFrame(
    val handle: String,
    val width: Int,
    val height: Int,
    /** SHA-256 of the JPEG bytes. */
    val contentHash: String,
    /** True when at least one mask rectangle was filled before encoding. */
    val masked: Boolean,
    val byteLength: Int,
    val captureMicros: Long,
    val dHash: String,
    /** The visible structure the masks were computed from (copy time). */
    val structureSignature: String,
    val maskCoverage: MaskCoverage,
    /** The masks' walk met a region host, whose content [structureSignature] does not cover. */
    val hasRegionHosts: Boolean,
)

/** The capture boundary in logical pixels (dp) of the window's decor view. */
internal data class BoundaryRect(val x: Double, val y: Double, val width: Double, val height: Double) {
    fun toJson(): JSONObject = JSONObject().put("x", x).put("y", y).put("width", width).put("height", height)
}

/** The `timings` group; it feeds the engine's screenshot budget. */
internal data class CaptureTimingsMicros(
    val frameWaitMicros: Long = 0,
    val readbackMicros: Long = 0,
    val maskMicros: Long = 0,
    val encodeMicros: Long = 0,
)

/** The engine's closed failure vocabulary (Dart `ScreenshotCaptureFailure`). */
internal enum class CaptureFailure(val wire: String) {
    BoundaryUnavailable("boundaryUnavailable"),
    LayoutUnavailable("layoutUnavailable"),
    PaintTimedOut("paintTimedOut"),
    ReadbackFailed("readbackFailed"),
    MaskFailed("maskFailed"),
    EncodingFailed("encodingFailed"),

    /** A `FLAG_SECURE` window: never copied. */
    SecureWindow("secureWindow"),
}
