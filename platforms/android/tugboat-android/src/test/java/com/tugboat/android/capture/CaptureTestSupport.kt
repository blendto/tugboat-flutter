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
import org.robolectric.Robolectric

/** Records runtime calls; completes them only when the test says so. */
internal class FakeWindowCapturer : WindowCapturer {
    val requests = ArrayList<CaptureRequest>()
    private val callbacks = HashMap<Long, (CaptureResult) -> Unit>()
    var throwOnCapture: Throwable? = null
    var disposed = false

    override fun capture(window: Window, request: CaptureRequest, onComplete: (CaptureResult) -> Unit) {
        throwOnCapture?.let { throw it }
        requests += request
        callbacks[request.requestId] = onComplete
    }

    override fun dispose() {
        disposed = true
    }

    fun complete(result: CaptureResult) = callbacks.getValue(result.requestId)(result)
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
) = CaptureRequestEffect(
    requestId = id,
    trigger = "interaction",
    force = force,
    requireFreshPaint = force,
    scale = scale,
    dHashBaseline = baseline,
)
