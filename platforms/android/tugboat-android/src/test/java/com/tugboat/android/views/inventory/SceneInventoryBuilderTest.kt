package com.tugboat.android.views.inventory

import android.app.Activity
import android.view.ViewGroup
import android.widget.Button
import android.widget.FrameLayout
import android.widget.LinearLayout
import com.tugboat.android.views.FixedRoutes
import com.tugboat.android.views.anchorResolver
import com.tugboat.android.views.identity.AndroidResourceNames
import com.tugboat.android.views.identity.CanonicalPathBuilder
import com.tugboat.android.views.layOut
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner

@RunWith(RobolectricTestRunner::class)
class SceneInventoryBuilderTest {
    @Test
    fun tappedControlFingerprintAppearsInInventory() {
        val activity = Robolectric.setupActivity(Activity::class.java)
        val button = Button(activity)
        val root = activity.findViewById<FrameLayout>(android.R.id.content)
        root.addView(
            LinearLayout(activity).apply {
                addView(button, ViewGroup.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 200))
            },
        )
        layOut(root)
        val routes = FixedRoutes(root)
        val names = AndroidResourceNames(activity.resources)
        val paths = CanonicalPathBuilder(names)
        val anchors = anchorResolver(root)
        val builder = SceneInventoryBuilder(names, routes, paths, anchors)
        val anchor = anchors.anchorFor(button, root)
        val inventory = builder.build(activity.window)
        if (inventory == null) {
            org.junit.Assert.fail("expected scene inventory")
            return
        }
        val elements = inventory.getJSONArray("elements")
        val fingerprints = (0 until elements.length()).map { elements.getJSONObject(it).getString("fingerprint") }
        val fingerprint = anchor?.fingerprint
        assertNotNull(fingerprint)
        assertTrue(fingerprint in fingerprints)
    }
}
