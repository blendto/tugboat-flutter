package com.tugboat.capture

data class CaptureCapabilities(
    val nativeCaptureSupported: Boolean,
    val apiLevel: Int,
    val minNativeApi: Int = CaptureRuntime.MIN_NATIVE_API,
)

enum class CaptureStatus {
    Ok,
    SkippedByDHash,
    UnsupportedApi,
    UnsupportedRenderMode,
    SurfaceUnavailable,
    Timeout,
    PixelCopyFailed,
    ProcessingFailed,
    Cancelled,
    Disposed,
    SecureWindow,
}

enum class CaptureCoverage {
    EngineSurface,
    WindowComposite,
}

enum class RenderMode {
    SurfaceView,
    TextureView,
    Hybrid,
    Unknown,
}

data class NormalizedMask(
    val x: Double,
    val y: Double,
    val width: Double,
    val height: Double,
)

data class CaptureRequest(
    val requestId: Long,
    val pixelWidth: Int,
    val pixelHeight: Int,
    val force: Boolean,
    val lastDHash: String = "",
    val masks: List<NormalizedMask> = emptyList(),
    /**
     * The visible structure [lastDHash] was captured with. When set, a window
     * capture with a [WindowMaskSupplier] offers [lastDHash] to the dHash skip
     * only if the supplied `MaskSnapshot.structureSignature` equals it.
     */
    val lastStructureSignature: String = "",
)

data class CaptureTimings(
    val surfaceCopyMicros: Long = 0,
    val maskFillMicros: Long = 0,
    val dHashMicros: Long = 0,
    val jpegMicros: Long = 0,
    val sha256Micros: Long = 0,
    val pixelReadbackMicros: Long = 0,
    /** Time the [WindowMaskSupplier] took on the main thread. */
    val maskComputeMicros: Long = 0,
)

data class CaptureResult(
    val requestId: Long,
    val status: CaptureStatus,
    val coverage: CaptureCoverage? = null,
    val jpeg: ByteArray = ByteArray(0),
    val width: Int = 0,
    val height: Int = 0,
    val dHash: String = "",
    val contentHash: String = "",
    val timings: CaptureTimings = CaptureTimings(),
    val renderMode: RenderMode = RenderMode.Unknown,
    val incomplete: Boolean = false,
    /** The masks this frame was filled with (window captures that reached the copy). */
    val maskSnapshot: MaskSnapshot? = null,
)
