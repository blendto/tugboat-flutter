package com.tugboat.android.views.inventory

import android.app.Activity
import android.widget.Button
import android.widget.FrameLayout
import com.tugboat.android.views.FixedRoutes
import com.tugboat.android.views.anchorResolver
import com.tugboat.android.views.identity.AndroidResourceNames
import com.tugboat.android.views.identity.CanonicalPathBuilder
import com.tugboat.android.views.layOut
import org.json.JSONObject
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner

@RunWith(RobolectricTestRunner::class)
class SceneInventoryFactContractTest {
    @Test
    fun builderOutputMatchesEngineFactKeys() {
        val activity = Robolectric.setupActivity(Activity::class.java)
        val button = Button(activity)
        val root = activity.findViewById<FrameLayout>(android.R.id.content)
        root.addView(button)
        layOut(root)
        val routes = FixedRoutes(root)
        val names = AndroidResourceNames(activity.resources)
        val paths = CanonicalPathBuilder(names)
        val anchors = anchorResolver(root)
        val inventory = SceneInventoryBuilder(names, routes, paths, anchors).build(activity.window)
        assertTrue(inventory != null)
        SceneInventoryFactContract.assertFact(inventory!!)
    }
}

/** Keys the session engine accepts on `scene.inventory` (see `decode_scene_inventory_fact`). */
internal object SceneInventoryFactContract {
    private val FACT_KEYS = setOf("routeKey", "elements")
    private val ELEMENT_KEYS = setOf(
        "fingerprint",
        "canonicalPath",
        "widgetType",
        "role",
        "actions",
        "enabled",
        "boundsNorm",
        "tier",
        "aliases",
    )
    private val BOUNDS_KEYS = setOf("left", "top", "width", "height")

    fun assertFact(json: JSONObject) {
        assertFalse("inventoryHash must not be sent on the fact", json.has("inventoryHash"))
        json.keys().forEach { key ->
            assertTrue("unknown fact key $key", key in FACT_KEYS)
        }
        val elements = json.getJSONArray("elements")
        for (i in 0 until elements.length()) {
            val element = elements.getJSONObject(i)
            element.keys().forEach { key ->
                assertTrue("unknown element key $key", key in ELEMENT_KEYS)
            }
            val bounds = element.getJSONObject("boundsNorm")
            bounds.keys().forEach { key ->
                assertTrue("unknown bounds key $key", key in BOUNDS_KEYS)
            }
        }
    }
}
