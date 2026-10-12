package com.tugboat.android.views

import android.graphics.RectF
import android.view.ViewGroup
import android.widget.LinearLayout
import android.widget.TextView
import com.tugboat.android.toolkit.RegionHit
import com.tugboat.android.views.identity.IdentityHash
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner

/** The toolkit-region seam's tap and anchor rules (generic: a fake region). */
@RunWith(RobolectricTestRunner::class)
class ToolkitRegionAnchorsTest {
    @get:Rule
    val regionRule = FakeRegionRule()
    private val region get() = regionRule.region

    private val label = TextView(context)
    private val host = FakeHostView(context)
    private val root = LinearLayout(context).apply {
        orientation = LinearLayout.VERTICAL
        addView(label, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 200))
        addView(host, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 600))
    }
    private val anchors = anchorResolver(root, routeKey = "/home")

    private fun tap(x: Float, y: Float): JSONObject {
        layOut(root)
        return anchors.tapEvidence(root, x, y).toJson()
    }

    @Test
    fun aRegionTargetIsPrefixedWithTheHostPathAndCarriesTheRegionToolkit() {
        region.hit = FakeRegion.target(listOf("Button#0"), tag = "pay", bounds = RectF(0f, 0f, 100f, 50f))
        val anchor = tap(50f, 300f).getJSONObject("anchor")
        assertEquals("Fake#0/Button#0", anchor.getString("canonicalPath"))
        assertEquals("compose", anchor.getString("toolkit"))
        assertEquals(IdentityHash.fingerprint(mapOf("routeKey" to "/home", "path" to "Fake#0/Button#0")), anchor.getString("fingerprint"))
        assertEquals(IdentityHash.fingerprint(mapOf("routeKey" to "/home", "tag" to "pay")), anchor.getString("tagFingerprint"))
        assertEquals("high", anchor.getString("fingerprintConfidence"))
        // Bounds are mapped out of the host: (0..50) in the host is y 200..250 in the window.
        assertEquals("top", anchor.getString("relativePosition"))
    }

    @Test
    fun anUnreadableRegionAnchorsItsHostWithTheRegionToolkit() {
        region.hit = RegionHit.Unreadable
        val anchor = tap(50f, 300f).getJSONObject("anchor")
        assertEquals("Fake#0", anchor.getString("canonicalPath"))
        assertEquals("Fake", anchor.getString("widgetType"))
        assertEquals("compose", anchor.getString("toolkit"))
        assertEquals("low", anchor.getString("fingerprintConfidence"))
    }

    @Test
    fun aThrowingRegionIsUnreadable() {
        region.throwing = true
        assertEquals("Fake#0", tap(50f, 300f).getJSONObject("anchor").getString("canonicalPath"))
    }

    @Test
    fun aMissFallsBackToTheViewsRules() {
        region.hit = RegionHit.Miss
        root.isClickable = true
        val anchor = tap(50f, 300f).getJSONObject("anchor")
        assertEquals("view", anchor.getString("toolkit"))
        assertEquals("LinearLayout", anchor.getString("widgetType"))
    }

    @Test
    fun theRegionRouteKeyOverridesTheViewsRoute() {
        region.hit = FakeRegion.target(listOf("Button#0"))
        region.route = "checkout"
        val anchor = tap(50f, 300f).getJSONObject("anchor")
        assertEquals("checkout", anchor.getJSONObject("fingerprintParts").getString("routeKey"))
        // Views targets keep the Views route.
        val views = tap(10f, 10f).getJSONObject("anchor")
        assertEquals("/home", views.getJSONObject("fingerprintParts").getString("routeKey"))
    }

    @Test
    fun theHostIsAKeptViewSoSiblingHostsGetOrdinals() {
        val second = FakeHostView(context)
        root.addView(second, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 100))
        region.hit = FakeRegion.target(listOf("Button#0"))
        layOut(root, heightPx = 1000)
        val anchor = anchors.tapEvidence(root, 50f, 850f).toJson().getJSONObject("anchor")
        assertEquals("Fake#1/Button#0", anchor.getString("canonicalPath"))
    }
}
