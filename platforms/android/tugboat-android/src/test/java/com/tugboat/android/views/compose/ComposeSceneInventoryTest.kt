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
import com.tugboat.android.views.inventory.SceneInventoryBuilder
import com.tugboat.android.views.layOut
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
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
        assertTapIsInInventory(FixedRoutes(decor))
    }

    /** The host itself is the route root, so its own path is empty: paths must not start with `/`. */
    @Test
    fun aHostThatIsItsRouteRootSharesTheTapPath() {
        compose.setContent {
            Column {
                Button(onClick = {}) { Text("Pay") }
            }
        }
        compose.waitForIdle()
        val decor = compose.activity.decor
        layOut(decor)
        val host = composeHost(decor)
        if (host == null) return fail("expected a Compose host")

        val paths = assertTapIsInInventory(FixedRoutes(host))
        assertTrue(paths.toString(), paths.none { it.startsWith("/") })
    }

    /** Asserts the tap fingerprint on "Pay" is an inventory element's; returns the element paths. */
    private fun assertTapIsInInventory(routes: FixedRoutes): List<String> {
        val decor = compose.activity.decor
        val names = AndroidResourceNames(compose.activity.resources)
        val anchors = AnchorResolver(names, routes)
        val tap = anchors.tapAt(compose.activity, compose.onNodeWithText("Pay"))
        assertNoText(tap, "Pay")
        val fingerprint = tap.anchor().getString("fingerprint")
        val inventory = SceneInventoryBuilder(names, routes, anchors).build(decor, routes.routeFor(decor))?.toJson()
        if (inventory == null) {
            fail("expected scene inventory")
            return emptyList()
        }
        assertNoText(inventory, "Pay")
        val elements = inventory.getJSONArray("elements")
        val byFingerprint = (0 until elements.length()).map { elements.getJSONObject(it) }.associateBy { it.getString("fingerprint") }
        assertTrue(byFingerprint.keys.toString(), fingerprint in byFingerprint)
        assertEquals(tap.anchor().getString("canonicalPath"), byFingerprint[fingerprint]?.getString("canonicalPath"))
        return byFingerprint.values.map { it.getString("canonicalPath") }
    }
}

class ComposeWholeHostSceneInventoryTest : ComposeSceneInventoryTest(ComposeMasking.WholeHost)

class ComposeSemanticsSceneInventoryTest : ComposeSceneInventoryTest(ComposeMasking.SemanticsBestEffort)
