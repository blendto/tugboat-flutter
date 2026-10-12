package com.tugboat.android.compose

import android.app.Activity
import android.view.View
import android.view.ViewGroup
import androidx.compose.ui.semantics.SemanticsNode
import androidx.compose.ui.test.SemanticsNodeInteraction
import com.tugboat.android.host.HostClock
import com.tugboat.android.host.HostTime
import com.tugboat.android.toolkit.ToolkitRegion
import com.tugboat.android.toolkit.ToolkitRegions
import com.tugboat.android.views.facts.FactClock
import com.tugboat.android.views.facts.ViewsFact
import com.tugboat.android.views.identity.AnchorResolver
import com.tugboat.android.views.identity.AndroidResourceNames
import com.tugboat.android.views.identity.TargetAnchor
import com.tugboat.android.views.navigation.DestinationTracker
import com.tugboat.android.views.navigation.ViewRouteResolver
import org.json.JSONObject
import org.junit.rules.ExternalResource

/** Registers [region] for one test, as `TugboatCompose.install` would, and removes it after. */
internal class RegionRule(val region: ToolkitRegion = ComposeRegion()) : ExternalResource() {
    override fun before() = ToolkitRegions.register(region)

    override fun after() = ToolkitRegions.unregister(region)
}

/** A resolver with the Views adapter's real routes: the activity class, or a tracked destination. */
internal fun anchorResolver(activity: Activity, destinations: DestinationTracker = DestinationTracker()) =
    AnchorResolver(AndroidResourceNames(activity.resources), ViewRouteResolver(destinations))

internal val Activity.decor: View
    get() = window.decorView

/** The tap evidence JSON at the center of [node] (window pixels are decor pixels). */
internal fun AnchorResolver.tapAt(activity: Activity, node: SemanticsNodeInteraction): JSONObject {
    val center = node.fetchSemanticsNode().boundsInWindow.center
    return tapEvidence(activity.decor, center.x, center.y).toJson()
}

internal fun JSONObject.anchor(): JSONObject = getJSONObject("anchor")

/** The first `AndroidComposeView` (a Compose host) under [view]. */
internal fun composeHost(view: View): View? {
    if (ComposeRegion.Default.hosts(view)) return view
    if (view is ViewGroup) {
        for (i in 0 until view.childCount) composeHost(view.getChildAt(i))?.let { return it }
    }
    return null
}

internal val SemanticsNodeInteraction.node: SemanticsNode
    get() = fetchSemanticsNode()

internal class ManualClock(var monoUs: Long = 1_000_000) : HostClock {
    override fun now(): HostTime = HostTime(monoUs, 1_791_712_345_678_901 + monoUs)

    fun advanceMs(ms: Long) {
        monoUs += ms * 1_000
    }
}

internal fun factClock(clock: ManualClock) = FactClock(clock)

internal class RecordingFacts {
    val facts = ArrayList<ViewsFact>()

    fun emit(fact: ViewsFact) {
        facts += fact
    }

    fun inputs(type: String) = facts.filter { it.type == type }.map { it.input }
}

/** The texts a test screen shows; none may appear in any anchor. */
internal fun assertNoText(anchor: TargetAnchor?, vararg texts: String) = assertNoText(anchor?.toJson(), *texts)

internal fun assertNoText(json: JSONObject?, vararg texts: String) {
    val serialized = json.toString()
    for (text in texts) check(!serialized.contains(text)) { "\"$text\" leaked into identity: $serialized" }
}
