package com.tugboat.capture

import android.os.Build
import android.view.View

/**
 * Published-package stub. Native CPU capture compiles from monorepo sources
 * under `platforms/android/capture-runtime` when that tree is present.
 */
class CaptureRuntime(
    @Suppress("UNUSED_PARAMETER") timeoutMs: Long = DEFAULT_TIMEOUT_MS,
) {
    fun capabilities(): CaptureCapabilities {
        val api = Build.VERSION.SDK_INT
        return CaptureCapabilities(
            nativeCaptureSupported = false,
            apiLevel = api,
        )
    }

    fun capture(view: View, request: CaptureRequest, onComplete: (CaptureResult) -> Unit) {
        onComplete(
            CaptureResult(
                requestId = request.requestId,
                status = CaptureStatus.UnsupportedApi,
            ),
        )
    }

    fun cancel(requestId: Long) {}

    fun dispose() {}

    companion object {
        const val MIN_NATIVE_API: Int = 24
        const val DEFAULT_TIMEOUT_MS: Long = 2_000
    }
}
