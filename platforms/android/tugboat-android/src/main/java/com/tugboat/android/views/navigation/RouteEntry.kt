package com.tugboat.android.views.navigation

import com.tugboat.android.views.identity.Confidence
import java.util.concurrent.atomic.AtomicLong

/** Engine `route.overlayKind` values (Dart `TugboatOverlayKind`). */
internal enum class OverlayKind(val wire: String) {
    Page("page"),
    Dialog("dialog"),
}

/**
 * One route on a navigator: an activity or a fragment instance. [instanceId]
 * is opaque and stable for the instance's lifetime, including a recreation
 * (configuration change, or an activity the system destroyed while in the
 * back stack). [routeKey] is the identity route key (and the fact's `name`),
 * fixed when the route is first shown.
 */
internal class RouteEntry(
    val instanceId: String,
    val routeKey: String,
    val confidence: Confidence,
    val type: String,
    val overlayKind: OverlayKind,
) {
    /**
     * True while the route's current owner is going away (a finishing
     * activity, a fragment being removed). Owners rebind it; a route whose
     * owner is gone reads as leaving, a parked route as staying.
     */
    var isLeaving: () -> Boolean = { false }

    override fun toString(): String = "$instanceId($routeKey)"

    companion object {
        private val next = AtomicLong(1)

        fun newInstanceId(prefix: String): String = "$prefix-${next.getAndIncrement()}"
    }
}
