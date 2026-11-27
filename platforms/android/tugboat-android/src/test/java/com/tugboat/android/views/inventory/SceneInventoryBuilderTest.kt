package com.tugboat.android.views.inventory

import android.app.Activity
import android.graphics.RectF
import android.view.ViewGroup
import android.widget.Button
import android.widget.FrameLayout
import android.widget.ImageView
import android.widget.LinearLayout
import com.tugboat.android.views.FixedRoutes
import com.tugboat.android.views.identity.AnchorResolver
import com.tugboat.android.views.identity.AndroidResourceNames
import com.tugboat.android.views.identity.IdCounts
import com.tugboat.android.views.layOut
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner

@RunWith(RobolectricTestRunner::class)
class SceneInventoryBuilderTest {
    private val activity = Robolectric.buildActivity(Activity::class.java).setup().get()
    private val root = activity.findViewById<FrameLayout>(android.R.id.content)
    private val routes = FixedRoutes(root)
    private val names = AndroidResourceNames(activity.resources)
    private val anchors = AnchorResolver(names, routes)
    private var idWalks = 0
    private val builder = SceneInventoryBuilder(names, routes, anchors, newIdCounts = { IdCounts { idWalks++ } })

    @Test
    fun tappedControlFingerprintAppearsInInventory() {
        val button = Button(activity)
        root.addView(
            LinearLayout(activity).apply {
                addView(button, ViewGroup.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 200))
            },
        )
        layOut(root.rootView)

        val inventory = build()

        SceneInventoryFactContract.assertFact(inventory)
        val fingerprint = anchors.anchorFor(button, root.rootView)?.fingerprint
        assertTrue(fingerprint != null && fingerprint in fingerprints(inventory))
    }

    @Test
    fun theWalkStopsCollectingAtTheLimitButCountsEveryCandidate() {
        val column = LinearLayout(activity).apply { orientation = LinearLayout.VERTICAL }
        repeat(5) { column.addView(Button(activity), LinearLayout.LayoutParams(300, 100)) }
        root.addView(column)
        layOut(root.rootView)

        val inventory = build(limit = 3)

        assertEquals(3, inventory.getJSONArray("elements").length())
        assertEquals(5, inventory.getInt("totalElements"))
        SceneInventoryFactContract.assertFact(inventory)
    }

    @Test
    fun resourceIdsAreCountedOncePerWalk() {
        val column = LinearLayout(activity).apply { orientation = LinearLayout.VERTICAL }
        for (id in FRAMEWORK_IDS) column.addView(Button(activity).apply { this.id = id }, LinearLayout.LayoutParams(300, 60))
        root.addView(column)
        layOut(root.rootView)

        val inventory = build()

        assertEquals(FRAMEWORK_IDS.size, inventory.getJSONArray("elements").length())
        assertEquals(1, idWalks)
        // A unique id is still the element's alias, as on its tap anchor.
        val alias = anchors.anchorFor(column.getChildAt(0), root.rootView)?.tagFingerprint
        assertEquals(listOf(alias), aliases(elements(inventory).first()))
    }

    @Test
    fun contentElementsCarryOnlyIdentityBoundsAndTheDisplayRole() {
        root.addView(ImageView(activity).apply { id = android.R.id.icon }, FrameLayout.LayoutParams(200, 200))
        layOut(root.rootView)

        val element = elements(build()).single()

        assertEquals("content", element.getString("tier"))
        assertEquals("display", element.getString("role"))
        assertEquals("ImageView", element.getString("widgetType"))
        assertFalse(element.has("aliases"))
        assertFalse(element.has("actions"))
        assertFalse(element.has("enabled"))
    }

    @Test
    fun nanBoundsAreNotNormalized() {
        assertNull(NormalizedBounds.of(RectF(Float.NaN, 0f, 10f, 10f), 100.0, 100.0))
        assertNull(NormalizedBounds.of(RectF(0f, 0f, 10f, Float.NaN), 100.0, 100.0))
        assertNull(NormalizedBounds.of(RectF(0f, 0f, 10f, 10f), Double.NaN, 100.0))
        assertNull(NormalizedBounds.of(RectF(10f, 0f, 10f, 10f), 100.0, 100.0))
        assertEquals(0.1, NormalizedBounds.of(RectF(0f, 0f, 10f, 10f), 100.0, 100.0)?.width ?: 0.0, 1e-12)
    }

    private fun build(limit: Int = SceneInventoryBuilder.MAX_ELEMENTS): JSONObject {
        val inventory = builder.build(root.rootView, routes.routeFor(root).value, limit)
        assertTrue("expected a scene inventory", inventory != null)
        return inventory?.toJson() ?: JSONObject()
    }

    private fun elements(inventory: JSONObject): List<JSONObject> {
        val array = inventory.getJSONArray("elements")
        return (0 until array.length()).map { array.getJSONObject(it) }
    }

    private fun aliases(element: JSONObject): List<String> {
        val array = element.optJSONArray("aliases") ?: return emptyList()
        return (0 until array.length()).map { array.getString(it) }
    }

    private fun fingerprints(inventory: JSONObject) = elements(inventory).map { it.getString("fingerprint") }

    private companion object {
        val FRAMEWORK_IDS = listOf(
            android.R.id.button1,
            android.R.id.button2,
            android.R.id.button3,
            android.R.id.checkbox,
            android.R.id.edit,
            android.R.id.icon1,
            android.R.id.icon2,
            android.R.id.message,
            android.R.id.summary,
            android.R.id.title,
        )
    }
}
