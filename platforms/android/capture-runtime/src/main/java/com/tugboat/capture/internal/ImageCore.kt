package com.tugboat.capture.internal

internal class NativeProcessResult(
    val status: Int,
    val dHash: String,
    val maskFillMicros: Long,
    val dHashMicros: Long,
)

internal object ImageCore {
    init {
        System.loadLibrary("tugboat_image_jni")
    }

    external fun process(
        bitmap: android.graphics.Bitmap,
        masksPacked: IntArray,
        lastDHash: String,
        force: Boolean,
    ): NativeProcessResult
}
