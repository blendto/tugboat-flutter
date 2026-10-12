package com.tugboat.android.compose

import androidx.activity.ComponentActivity
import androidx.compose.material3.Button
import androidx.compose.material3.Text
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.onNodeWithText
import com.tugboat.android.compose.navigation.RoutePattern
import com.tugboat.android.views.ViewsAdapter
import com.tugboat.android.views.facts.FactSink
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.rules.RuleChain
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner

/** Route keys: the `trackNavigation` route pattern without arguments, then the hosting activity. */
@RunWith(RobolectricTestRunner::class)
class ComposeRouteTest {
    private val compose = createAndroidComposeRule<ComponentActivity>()

    @get:Rule
    val rules: RuleChain = RuleChain.outerRule(RegionRule()).around(compose)

    @Before
    fun setUp() {
        compose.setContent { Button(onClick = {}) { Text("Pay") } }
    }

    private fun routeKey(): String =
        anchorResolver(compose.activity).tapAt(compose.activity, compose.onNodeWithText("Pay")).anchor()
            .getJSONObject("fingerprintParts").getString("routeKey")

    @Test
    fun theHostingActivityIsTheFallback() {
        assertEquals(ComponentActivity::class.java.name, routeKey())
    }

    @Test
    fun theViewsAdapterHookForwardsTheStrippedRoutePattern() {
        val adapter = ViewsAdapter(compose.activity.application, FactSink { }, frames = { })
        adapter.onDestinationChanged(compose.activity, "checkout/{orderId}?step={step}", 0)
        assertEquals("checkout", routeKey())
        adapter.onDestinationChanged(compose.activity, null, 0)
        assertEquals(ComponentActivity::class.java.name, routeKey())
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
