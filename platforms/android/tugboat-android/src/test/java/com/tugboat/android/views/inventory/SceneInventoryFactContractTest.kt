package com.tugboat.android.views.inventory

import android.app.Activity
import android.widget.Button
import android.widget.FrameLayout
import com.tugboat.android.views.FixedRoutes
import com.tugboat.android.views.identity.AnchorResolver
import com.tugboat.android.views.identity.AndroidResourceNames
import com.tugboat.android.views.layOut
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner

@RunWith(RobolectricTestRunner::class)
class SceneInventoryFactContractTest {
    @Test
    fun builderOutputMeetsEveryDecoderRule() {
        val activity = Robolectric.buildActivity(Activity::class.java).setup().get()
        val root = activity.findViewById<FrameLayout>(android.R.id.content)
        // A clickable route root: its own path is "".
        val screen = FrameLayout(activity).apply { isClickable = true }
        screen.addView(Button(activity), FrameLayout.LayoutParams(300, 200))
        root.addView(screen)
        layOut(root.rootView)
        val routes = FixedRoutes(screen)
        val names = AndroidResourceNames(activity.resources)
        val inventory = SceneInventoryBuilder(names, routes, AnchorResolver(names, routes))
            .build(root.rootView, routes.routeFor(screen))
            ?.toJson()
        if (inventory == null) return fail("expected a scene inventory")

        SceneInventoryFactContract.assertFact(inventory)
        val paths = (0 until inventory.getJSONArray("elements").length())
            .map { inventory.getJSONArray("elements").getJSONObject(it).getString("canonicalPath") }
        assertEquals(listOf("", "Button#0"), paths)
    }

    @Test
    fun theMirrorRejectsWhatTheDecoderRejects() {
        val valid = JSONObject(VALID)
        SceneInventoryFactContract.assertFact(valid)
        val invalid = listOf(
            "inventoryHash" to { it: JSONObject -> it.put("inventoryHash", "0123456789abcdef") },
            "empty fingerprint" to { it: JSONObject -> it.element().put("fingerprint", "") },
            "unknown tier" to { it: JSONObject -> it.element().put("tier", "chrome") },
            "negative left" to { it: JSONObject -> it.bounds().put("left", -0.1) },
            "zero width" to { it: JSONObject -> it.bounds().put("width", 0.0) },
            "past the right edge" to { it: JSONObject -> it.bounds().put("left", 0.5).put("width", 0.501) },
            "extra bounds key" to { it: JSONObject -> it.bounds().put("right", 1.0) },
            "unknown element key" to { it: JSONObject -> it.element().put("label", "x") },
            "non-string action" to { it: JSONObject -> it.element().put("actions", JSONArray().put(1)) },
            "too many aliases" to { it: JSONObject -> it.element().put("aliases", JSONArray(List(17) { "a$it" })) },
            "long path" to { it: JSONObject -> it.element().put("canonicalPath", "x".repeat(1025)) },
            "total below elements" to { it: JSONObject -> it.put("totalElements", 0) },
            "non-integer total" to { it: JSONObject -> it.put("totalElements", 1.5) },
        )
        for ((name, mutate) in invalid) {
            val json = JSONObject(VALID).apply { mutate(this) }
            val rejected = runCatching { SceneInventoryFactContract.assertFact(json) }.isFailure
            assertTrue("the contract mirror accepted $name", rejected)
        }
        // Accepted: the bounds epsilon, and an empty canonicalPath.
        SceneInventoryFactContract.assertFact(JSONObject(VALID).also { it.bounds().put("left", 0.5).put("width", 0.5000000001) })
        SceneInventoryFactContract.assertFact(JSONObject(VALID).also { it.element().put("canonicalPath", "") })
    }

    private fun JSONObject.element(): JSONObject = getJSONArray("elements").getJSONObject(0)

    private fun JSONObject.bounds(): JSONObject = element().getJSONObject("boundsNorm")

    private companion object {
        const val VALID =
            """{"routeKey":"home","totalElements":1,"elements":[{"fingerprint":"0123456789abcdef","canonicalPath":"Button#0",""" +
                """"widgetType":"Button","role":"button","actions":["tap"],"enabled":true,""" +
                """"boundsNorm":{"left":0.1,"top":0.2,"width":0.3,"height":0.1},"tier":"interactive","aliases":["fedcba9876543210"]}]}"""
    }
}
