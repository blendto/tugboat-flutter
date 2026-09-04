package com.tugboat.flutter

import android.app.Activity
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.view.View
import android.view.ViewGroup
import com.tugboat.capture.CaptureCapabilities
import com.tugboat.capture.CaptureCoverage
import com.tugboat.capture.CaptureRequest
import com.tugboat.capture.CaptureResult
import com.tugboat.capture.CaptureRuntime
import com.tugboat.capture.CaptureStatus
import com.tugboat.capture.CaptureTimings
import com.tugboat.capture.NormalizedMask
import com.tugboat.capture.RenderMode
import io.flutter.embedding.android.FlutterView
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodChannel

/// Device Farm launch extras read from the host `Intent`.
///
/// Natives pass raw strings through; all `1`/`true`/`yes` normalization and
/// local-URL validation lives in `TugboatLaunchParsers` on the Dart side.
const val TUGBOAT_EMIT_SCENE_INVENTORY = "tugboat_emit_scene_inventory"
const val TUGBOAT_ACCEPT_ACTION_CONTEXT = "tugboat_accept_action_context"
const val TUGBOAT_COLLECTOR_BASE_URL = "tugboat_collector_base_url"

class TugboatPlugin :
    FlutterPlugin,
    ActivityAware,
    NativeCaptureHostApi {
    private var runtime: CaptureRuntime? = null
    private var activity: Activity? = null
    private val mainHandler = Handler(Looper.getMainLooper())
    private var launchChannel: MethodChannel? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        runtime = CaptureRuntime()
        NativeCaptureHostApi.setUp(binding.binaryMessenger, this)
        launchChannel = MethodChannel(binding.binaryMessenger, "tugboat/launch").also { channel ->
            channel.setMethodCallHandler { call, result ->
                if (call.method == "getLaunchOptions") {
                    result.success(launchOptions())
                } else {
                    result.notImplemented()
                }
            }
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        launchChannel?.setMethodCallHandler(null)
        launchChannel = null
        NativeCaptureHostApi.setUp(binding.binaryMessenger, null)
        runtime?.dispose()
        runtime = null
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activity = binding.activity
    }

    override fun onDetachedFromActivityForConfigChanges() {
        activity = null
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        activity = binding.activity
    }

    override fun onDetachedFromActivity() {
        activity = null
    }

    override fun getCapabilities(): NativeCaptureCapabilities {
        return requireRuntime().capabilities().toPigeon()
    }

    override fun capture(
        request: NativeCaptureRequest,
        callback: (Result<NativeCaptureResult>) -> Unit,
    ) {
        val view = flutterView()
        if (view == null) {
            callback(Result.success(request.toFailed(NativeCaptureStatus.SURFACE_UNAVAILABLE)))
            return
        }
        requireRuntime().capture(view, request.toRuntime()) { result ->
            mainHandler.post { callback(Result.success(result.toPigeon())) }
        }
    }

    override fun cancel(requestId: Long) {
        runtime?.cancel(requestId)
    }

    override fun dispose() {
        runtime?.dispose()
        runtime = null
    }

    private fun requireRuntime(): CaptureRuntime {
        val current = runtime
        if (current != null) return current
        return CaptureRuntime().also { runtime = it }
    }

    private fun flutterView(): View? {
        val root = activity?.window?.decorView?.rootView ?: return null
        return findFlutterView(root)
    }

    private fun launchOptions(): Map<String, Any?> {
        val intent = activity?.intent
        val extras = intent?.extras
        return mapOf(
            "emitSceneInventory" to rawExtra(extras, TUGBOAT_EMIT_SCENE_INVENTORY),
            "acceptActionContext" to rawExtra(extras, TUGBOAT_ACCEPT_ACTION_CONTEXT),
            "collectorBaseUrl" to (
                intent?.getStringExtra(TUGBOAT_COLLECTOR_BASE_URL)
                    ?: rawExtra(extras, TUGBOAT_COLLECTOR_BASE_URL)
                ),
        )
    }

    private fun rawExtra(extras: Bundle?, name: String): String? =
        extras?.get(name)?.toString()

    private fun findFlutterView(view: View): View? {
        if (view is FlutterView) return view
        if (view is ViewGroup) {
            for (i in 0 until view.childCount) {
                val found = findFlutterView(view.getChildAt(i))
                if (found != null) return found
            }
        }
        return null
    }
}

private fun CaptureCapabilities.toPigeon(): NativeCaptureCapabilities =
    NativeCaptureCapabilities(
        nativeCaptureSupported = nativeCaptureSupported,
        apiLevel = apiLevel.toLong(),
        minNativeApi = minNativeApi.toLong(),
    )

private fun NativeCaptureRequest.toRuntime(): CaptureRequest =
    CaptureRequest(
        requestId = requestId,
        pixelWidth = pixelWidth.toInt(),
        pixelHeight = pixelHeight.toInt(),
        force = force,
        lastDHash = lastDHash,
        masks = masks.map { NormalizedMask(it.x, it.y, it.width, it.height) },
    )

private fun NativeCaptureRequest.toFailed(status: NativeCaptureStatus): NativeCaptureResult =
    NativeCaptureResult(
        requestId = requestId,
        status = status,
        jpeg = ByteArray(0),
        width = 0,
        height = 0,
        dHash = "",
        contentHash = "",
        timings = emptyTimings(),
        renderMode = NativeCaptureRenderMode.UNKNOWN,
        incomplete = false,
    )

private fun CaptureResult.toPigeon(): NativeCaptureResult =
    NativeCaptureResult(
        requestId = requestId,
        status = status.toPigeon(),
        coverage = coverage?.toPigeon(),
        jpeg = jpeg,
        width = width.toLong(),
        height = height.toLong(),
        dHash = dHash,
        contentHash = contentHash,
        timings = timings.toPigeon(),
        renderMode = renderMode.toPigeon(),
        incomplete = incomplete,
    )

private fun CaptureStatus.toPigeon(): NativeCaptureStatus =
    when (this) {
        CaptureStatus.Ok -> NativeCaptureStatus.OK
        CaptureStatus.SkippedByDHash -> NativeCaptureStatus.SKIPPED_BY_DHASH
        CaptureStatus.UnsupportedApi -> NativeCaptureStatus.UNSUPPORTED_API
        CaptureStatus.UnsupportedRenderMode -> NativeCaptureStatus.UNSUPPORTED_RENDER_MODE
        CaptureStatus.SurfaceUnavailable -> NativeCaptureStatus.SURFACE_UNAVAILABLE
        CaptureStatus.Timeout -> NativeCaptureStatus.TIMEOUT
        CaptureStatus.PixelCopyFailed -> NativeCaptureStatus.PIXEL_COPY_FAILED
        CaptureStatus.ProcessingFailed -> NativeCaptureStatus.PROCESSING_FAILED
        CaptureStatus.Cancelled -> NativeCaptureStatus.CANCELLED
        CaptureStatus.Disposed -> NativeCaptureStatus.DISPOSED
    }

private fun CaptureCoverage.toPigeon(): NativeCaptureCoverage =
    when (this) {
        CaptureCoverage.EngineSurface -> NativeCaptureCoverage.ENGINE_SURFACE
    }

private fun RenderMode.toPigeon(): NativeCaptureRenderMode =
    when (this) {
        RenderMode.SurfaceView -> NativeCaptureRenderMode.SURFACE_VIEW
        RenderMode.TextureView -> NativeCaptureRenderMode.TEXTURE_VIEW
        RenderMode.Hybrid -> NativeCaptureRenderMode.HYBRID
        RenderMode.Unknown -> NativeCaptureRenderMode.UNKNOWN
    }

private fun CaptureTimings.toPigeon(): NativeCaptureTimings =
    NativeCaptureTimings(
        surfaceCopyMicros = surfaceCopyMicros,
        maskFillMicros = maskFillMicros,
        dHashMicros = dHashMicros,
        jpegMicros = jpegMicros,
        sha256Micros = sha256Micros,
        pixelReadbackMicros = pixelReadbackMicros,
    )

private fun emptyTimings(): NativeCaptureTimings =
    NativeCaptureTimings(
        surfaceCopyMicros = 0,
        maskFillMicros = 0,
        dHashMicros = 0,
        jpegMicros = 0,
        sha256Micros = 0,
        pixelReadbackMicros = 0,
    )
