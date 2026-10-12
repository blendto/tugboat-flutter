package com.tugboat.android.capture

import android.app.Activity
import android.view.View
import android.view.Window
import android.widget.FrameLayout
import android.widget.TextView
import com.tugboat.android.host.CaptureRequestEffect
import com.tugboat.android.host.DHashBaseline
import com.tugboat.capture.CaptureRequest
import com.tugboat.capture.CaptureResult
import com.tugboat.capture.MaskSnapshot
import com.tugboat.capture.WindowMaskSupplier
import org.robolectric.Robolectric

/**
 * Records runtime calls and completes them only when the test says so. Like
 * the real runtime, it takes the masks ([copy]) right before completing.
 */
internal class FakeWindowCapturer : WindowCapturer {
    class Call(val window: Window, val request: CaptureRequest, val masks: WindowMaskSupplier, val onComplete: (CaptureResult) -> Unit)

    val calls = ArrayList<Call>()
    val requests: List<CaptureRequest>
        get() = calls.map { it.request }
    var throwOnCapture: Throwable? = null
    var disposed = false

    override fun capture(window: Window, request: CaptureRequest, masks: WindowMaskSupplier, onComplete: (CaptureResult) -> Unit) {
        throwOnCapture?.let { throw it }
        calls += Call(window, request, masks, onComplete)
    }

    override fun dispose() {
        disposed = true
    }

    /** The main-thread step right before `PixelCopy.request`: takes the masks. */
    fun copy(id: Long): MaskSnapshot {
        val call = calls.first { it.request.requestId == id }
        return call.masks.masksFor(call.window)
    }

    /** Takes the masks (as a copy would) and completes with [result]. */
    fun complete(result: CaptureResult) {
        copy(result.requestId)
        calls.first { it.request.requestId == result.requestId }.onComplete(result)
    }
}

/** An activity whose decor view is laid out at [widthPx] x [heightPx] with one text view. */
internal fun laidOutWindow(widthPx: Int = 1080, heightPx: Int = 2400): Window {
    val activity = Robolectric.buildActivity(Activity::class.java).setup().get()
    activity.setContentView(FrameLayout(activity).apply { addView(TextView(activity), FrameLayout.LayoutParams(100, 100)) })
    val decor = activity.window.decorView
    decor.measure(
        View.MeasureSpec.makeMeasureSpec(widthPx, View.MeasureSpec.EXACTLY),
        View.MeasureSpec.makeMeasureSpec(heightPx, View.MeasureSpec.EXACTLY),
    )
    decor.layout(0, 0, widthPx, heightPx)
    return activity.window
}

internal fun captureRequest(
    id: String,
    force: Boolean = true,
    scale: Double = 1.0,
    baseline: DHashBaseline? = null,
) = CaptureRequestEffect(requestId = id, force = force, scale = scale, dHashBaseline = baseline)
