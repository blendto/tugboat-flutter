package com.tugboat.android.views.compose

import androidx.activity.ComponentActivity
import androidx.compose.foundation.layout.Column
import androidx.compose.material3.Button
import androidx.compose.material3.Text
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.onNodeWithText
import com.tugboat.android.compose.ComposeMasking
import com.tugboat.android.views.FixedRoutes
import com.tugboat.android.views.identity.AndroidResourceNames
import com.tugboat.android.views.identity.AnchorResolver
import com.tugboat.android.views.identity.CanonicalPathBuilder
import com.tugboat.android.views.inventory.SceneInventoryBuilder
import com.tugboat.android.views.layOut
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.RuleChain
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner

/** Scene inventory through the Views builder for a Compose host, both masking modes. */
@RunWith(RobolectricTestRunner::class)
abstract class ComposeSceneInventoryTest(masking: ComposeMasking) {
    protected val compose = createAndroidComposeRule<ComponentActivity>()

    @get:Rule
    val rules: RuleChain = RuleChain.outerRule(ComposeInstallRule(masking)).around(compose)

    @Test
    fun tappedControlFingerprintIsInInventoryWithoutVisibleText() {
        compose.setContent {
            Column {
                Button(onClick = {}) { Text("Pay") }
            }
        }
        compose.waitForIdle()
        val decor = compose.activity.decor
        layOut(decor)
        composeHost(decor)?.let { host ->
            if (host.width <= 0 || host.height <= 0) layOut(host)
        }
        val routes = FixedRoutes(decor)
        val names = AndroidResourceNames(compose.activity.resources)
        val paths = CanonicalPathBuilder(names)
        val anchors = AnchorResolver(names, routes)
        val builder = SceneInventoryBuilder(names, routes, paths, anchors)
        val tap = anchors.tapAt(compose.activity, compose.onNodeWithText("Pay"))
        assertNoText(tap, "Pay")
        val fingerprint = tap.anchor().getString("fingerprint")
        val inventory = builder.build(compose.activity.window)
        if (inventory == null) {
            org.junit.Assert.fail("expected scene inventory")
            return
        }
        assertNoText(inventory, "Pay")
        val elements = inventory.getJSONArray("elements")
        val fingerprints = (0 until elements.length()).map { elements.getJSONObject(it).getString("fingerprint") }
        assertTrue(fingerprint in fingerprints)
    }
}

class ComposeWholeHostSceneInventoryTest : ComposeSceneInventoryTest(ComposeMasking.WholeHost)

class ComposeSemanticsSceneInventoryTest : ComposeSceneInventoryTest(ComposeMasking.SemanticsBestEffort)
