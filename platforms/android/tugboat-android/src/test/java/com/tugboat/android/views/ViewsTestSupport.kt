package com.tugboat.android.views

import android.content.Context
import android.view.View
import com.tugboat.android.host.EngineMessage
import com.tugboat.android.host.FakeClock
import com.tugboat.android.views.facts.FactClock
import com.tugboat.android.views.facts.FactSink
import com.tugboat.android.views.facts.FrameScheduler
import com.tugboat.android.views.facts.ViewsFact
import com.tugboat.android.views.identity.AnchorResolver
import com.tugboat.android.views.identity.AndroidResourceNames
import com.tugboat.android.views.identity.Confidence
import com.tugboat.android.views.identity.RouteKey
import com.tugboat.android.views.identity.RouteResolver
import org.robolectric.RuntimeEnvironment

internal val context: Context
    get() = RuntimeEnvironment.getApplication()

/** Measures and lays out [root] at an exact pixel size, without a window. */
internal fun layOut(root: View, widthPx: Int = 720, heightPx: Int = 1280) {
    root.measure(
        View.MeasureSpec.makeMeasureSpec(widthPx, View.MeasureSpec.EXACTLY),
        View.MeasureSpec.makeMeasureSpec(heightPx, View.MeasureSpec.EXACTLY),
    )
    root.layout(0, 0, widthPx, heightPx)
}

/** Every view's route is [routeKey], with paths below [root]. */
internal class FixedRoutes(private val root: View, private val routeKey: String = "/home") : RouteResolver {
    override fun routeFor(view: View): RouteKey = RouteKey(routeKey, Confidence.High, root)
}

internal fun anchorResolver(root: View, routeKey: String = "/home") =
    AnchorResolver(AndroidResourceNames(context.resources), FixedRoutes(root, routeKey))

internal class RecordingFacts {
    val facts = ArrayList<ViewsFact>()

    fun emit(fact: ViewsFact) {
        facts += fact
    }

    fun ofType(type: String) = facts.filter { it.type == type }

    fun inputs(type: String) = ofType(type).map { it.input }
}

/** Frames run only when the test calls [runFrame]. */
internal class ManualFrames : FrameScheduler {
    private val pending = ArrayList<() -> Unit>()

    override fun postFrame(callback: () -> Unit) {
        pending += callback
    }

    fun runFrame() {
        val callbacks = pending.toList()
        pending.clear()
        callbacks.forEach { it() }
    }

    val hasPending: Boolean
        get() = pending.isNotEmpty()
}

internal class RecordingSink : FactSink {
    val batches = ArrayList<List<EngineMessage>>()

    override fun postBatch(messages: List<EngineMessage>) {
        batches += messages
    }
}

internal fun factClock(clock: FakeClock = FakeClock()) = FactClock(clock)
