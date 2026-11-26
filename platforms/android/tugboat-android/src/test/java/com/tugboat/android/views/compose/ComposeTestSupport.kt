package com.tugboat.android.views.compose

import android.app.Activity
import android.view.View
import android.view.ViewGroup
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.platform.ViewRootForTest
import androidx.compose.ui.semantics.SemanticsNode
import androidx.compose.ui.test.SemanticsNodeInteraction
import com.tugboat.android.compose.ComposeMasking
import com.tugboat.android.compose.TugboatCompose
import com.tugboat.android.toolkit.ToolkitRegions
import com.tugboat.android.views.identity.AnchorResolver
import com.tugboat.android.views.identity.AndroidResourceNames
import com.tugboat.android.views.mask.MaskRect
import com.tugboat.android.views.navigation.DestinationTracker
import com.tugboat.android.views.navigation.ViewRouteResolver
import org.json.JSONObject
import org.junit.rules.ExternalResource

/** Installs the Compose adapter for one test, as the SDK facade would, and removes it after. */
internal class ComposeInstallRule(private val masking: ComposeMasking = ComposeMasking.WholeHost) : ExternalResource() {
    override fun before() = TugboatCompose.install(masking)

    override fun after() = ToolkitRegions.all.toList().forEach(ToolkitRegions::unregister)
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

/** The first Compose host (`AndroidComposeView`) under [view]. */
internal fun composeHost(view: View): View? {
    if (view is ViewRootForTest) return view
    if (view is ViewGroup) {
        for (i in 0 until view.childCount) composeHost(view.getChildAt(i))?.let { return it }
    }
    return null
}

internal val SemanticsNodeInteraction.node: SemanticsNode
    get() = fetchSemanticsNode()

/** Whether a mask in [rects] covers [bounds] (decor pixels) of a [decor]-sized frame. */
internal fun covered(rects: List<MaskRect>, bounds: Rect, decor: View): Boolean {
    val w = decor.width.toDouble()
    val h = decor.height.toDouble()
    val slack = 1e-6
    return rects.any {
        it.x * w <= bounds.left + slack && it.y * h <= bounds.top + slack &&
            (it.x + it.width) * w >= bounds.right - slack && (it.y + it.height) * h >= bounds.bottom - slack
    }
}

/** The texts a test screen shows; none may appear in any anchor. */
internal fun assertNoText(json: JSONObject?, vararg texts: String) {
    val serialized = json.toString()
    for (text in texts) check(!serialized.contains(text)) { "\"$text\" leaked into identity: $serialized" }
}
