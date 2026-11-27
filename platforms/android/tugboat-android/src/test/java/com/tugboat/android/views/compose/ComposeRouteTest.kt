package com.tugboat.android.views.compose

import android.widget.Button
import android.widget.LinearLayout
import androidx.activity.ComponentActivity
import androidx.compose.material3.Text
import androidx.compose.ui.platform.ComposeView
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.onNodeWithText
import com.tugboat.android.views.navigation.DestinationTracker
import com.tugboat.android.views.navigation.RoutePattern
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.rules.RuleChain
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import androidx.compose.material3.Button as ComposeButton

/**
 * One route key for Views and Compose (native SDK note 6.1, 6.2): the
 * `trackNavigation` route pattern without arguments, normalized once by the
 * Views adapter's `DestinationTracker`, else the hosting activity.
 */
@RunWith(RobolectricTestRunner::class)
class ComposeRouteTest {
    private val compose = createAndroidComposeRule<ComponentActivity>()

    @get:Rule
    val rules: RuleChain = RuleChain.outerRule(ComposeInstallRule()).around(compose)

    private val destinations = DestinationTracker()
    private lateinit var viewsButton: Button

    @Before
    fun setUp() {
        compose.activityRule.scenario.onActivity { activity ->
            viewsButton = Button(activity)
            val screen = LinearLayout(activity).apply {
                orientation = LinearLayout.VERTICAL
                addView(viewsButton, LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, 80))
                addView(ComposeView(activity).apply { setContent { ComposeButton(onClick = {}) { Text("Pay") } } })
            }
            activity.setContentView(screen)
        }
        compose.waitForIdle()
    }

    private fun composeRouteKey(): String =
        anchorResolver(compose.activity, destinations).tapAt(compose.activity, compose.onNodeWithText("Pay")).anchor()
            .getJSONObject("fingerprintParts").getString("routeKey")

    private fun viewsRouteKey(): String =
        anchorResolver(compose.activity, destinations).anchorFor(viewsButton)!!.routeKey

    @Test
    fun theHostingActivityIsTheFallback() {
        assertEquals(ComponentActivity::class.java.name, composeRouteKey())
    }

    @Test
    fun viewsAndComposeShareTheStrippedRoutePattern() {
        destinations.onDestinationChanged(compose.activity, "checkout/{orderId}?step={step}", 0)
        assertEquals("checkout", composeRouteKey())
        assertEquals("checkout", viewsRouteKey())
        destinations.onDestinationChanged(compose.activity, null, 0)
        assertEquals(ComponentActivity::class.java.name, composeRouteKey())
    }

    @Test
    fun routePatternsLoseTheirArguments() {
        assertEquals("profile", RoutePattern.strip("profile/{userId}"))
        assertEquals("settings/privacy", RoutePattern.strip("settings/privacy?from={from}"))
        assertEquals("com.example.Profile", RoutePattern.strip("com.example.Profile/{id}?tab={tab}"))
        assertNull(RoutePattern.strip("{id}"))
        assertNull(RoutePattern.strip(null))
    }
}
