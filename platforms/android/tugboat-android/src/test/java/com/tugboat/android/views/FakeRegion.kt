package com.tugboat.android.views

import android.app.Activity
import android.content.Context
import android.graphics.RectF
import android.view.View
import android.widget.FrameLayout
import com.tugboat.android.toolkit.RegionFocus
import com.tugboat.android.toolkit.RegionHit
import com.tugboat.android.toolkit.RegionMasks
import com.tugboat.android.toolkit.RegionScrollable
import com.tugboat.android.toolkit.ToolkitRegion
import com.tugboat.android.toolkit.ToolkitRegions
import org.junit.rules.ExternalResource

/** A View hosting a fake toolkit's content. */
class FakeHostView(context: Context) : FrameLayout(context)

/** A scriptable toolkit region hosting [FakeHostView]s; every answer can be replaced, or made to throw. */
class FakeRegion : ToolkitRegion {
    var hit: RegionHit = RegionHit.Miss
    var masks = RegionMasks(emptyList(), wholeFrame = false)
    var scrollables: List<RegionScrollable> = emptyList()
    var focus: RegionFocus? = null
    var route: String? = null
    var throwing = false
    val destinations = ArrayList<Pair<Activity, String?>>()

    override val toolkit = "compose"
    override val hostToken = "Fake"

    override fun hosts(view: View) = view is FakeHostView

    override fun targetAt(host: View, x: Float, y: Float): RegionHit = answer { hit }

    override fun scrollables(host: View): List<RegionScrollable> = answer { scrollables }

    override fun masks(host: View): RegionMasks = answer { masks }

    override fun focus(host: View): RegionFocus? = answer { focus }

    override fun routeKey(host: View): String? = answer { route }

    override fun onDestinationChanged(activity: Activity, route: String?) {
        destinations += activity to route
    }

    private fun <T> answer(value: () -> T): T = if (throwing) error("region failure") else value()

    companion object {
        fun target(path: List<String>, tag: String? = null, bounds: RectF = RectF(0f, 0f, 10f, 10f)) =
            RegionHit.Target(path, "Button", "button", listOf("tap"), true, tag, inListItem = false, bounds = bounds)
    }
}

/** Registers a [FakeRegion] for one test. */
class FakeRegionRule : ExternalResource() {
    val region = FakeRegion()

    override fun before() = ToolkitRegions.register(region)

    override fun after() = ToolkitRegions.unregister(region)
}
