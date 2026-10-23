package com.tugboat.android.views.inventory

import android.app.Application
import android.view.View
import android.widget.Button
import android.widget.FrameLayout
import android.widget.ImageView
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.tugboat.android.AppInfo
import com.tugboat.android.CollectorConfig
import com.tugboat.android.TugboatConfig
import com.tugboat.android.engine.EngineResponse
import com.tugboat.android.engine.EngineStatus
import com.tugboat.android.engine.JniEngineTransport
import com.tugboat.android.host.EngineMessage
import com.tugboat.android.host.SystemHostClock
import com.tugboat.android.sdk.DeviceSnapshot
import com.tugboat.android.sdk.EngineConfiguration
import com.tugboat.android.sdk.HostMetadata
import com.tugboat.android.sdk.SessionMessages
import com.tugboat.android.views.identity.AnchorResolver
import com.tugboat.android.views.identity.AndroidResourceNames
import com.tugboat.android.views.identity.Confidence
import com.tugboat.android.views.identity.RouteKey
import com.tugboat.android.views.identity.RouteResolver
import com.tugboat.android.views.input.GestureConfig
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

/**
 * The builder's real output, sent as a `scene.inventory` fact in a `batch`
 * (as `EngineHost.postBatch` does) to the real `libtugboat_engine.so`: the
 * engine accepts it, including a route root's empty `canonicalPath`, and
 * records `scene_inventory`.
 */
@RunWith(AndroidJUnit4::class)
class SceneInventoryEngineTest {
    private val context = InstrumentationRegistry.getInstrumentation().targetContext.applicationContext as Application
    private val transport = checkNotNull(JniEngineTransport.open()) { "libtugboat_engine.so must load" }

    @After
    fun tearDown() = transport.close()

    @Test
    fun builderOutputIsAcceptedByTheEngine() {
        val app = AppInfo("Contract", "3.1.4", "314", "com.tugboat.contract", "install-contract")
        val config = TugboatConfig(CollectorConfig("http://127.0.0.1:9", "key"), app, emitSceneInventory = true)
        val device = DeviceSnapshot.read(context)
        val metadata = HostMetadata(app, device)
        val configure = EngineConfiguration.build(config, metadata, GestureConfig.from(context)).toString()
        assertOk(submit(EngineMessage(SessionMessages.ENGINE_CONFIGURE, configure, at = null).toJson()))
        val start = SessionMessages.sessionStart(device, metadata, 0, activationRequestId = null, explorationRunId = null)
        assertOk(submit(EngineMessage(SessionMessages.SESSION_START, start, SystemHostClock.now()).toJson()))

        val input = buildInventory()
        SceneInventoryFactContract.assertFact(input)
        val fact = EngineMessage("scene.inventory", input.toString(), SystemHostClock.now())
        val response = submit(EngineMessage.batchJson(listOf(fact)))

        assertOk(response)
        val text = response.text()
        assertTrue(text, text.contains("\"type\":\"scene_inventory\""))
        assertTrue(text, text.contains("\"canonicalPath\":\"\""))
    }

    /** A clickable route root (its own path is "") holding a button and an image, on the main thread. */
    private fun buildInventory(): JSONObject {
        var input: JSONObject? = null
        InstrumentationRegistry.getInstrumentation().runOnMainSync {
            val decor = FrameLayout(context)
            val screen = FrameLayout(context).apply { isClickable = true }
            screen.addView(Button(context), FrameLayout.LayoutParams(300, 120))
            screen.addView(ImageView(context), FrameLayout.LayoutParams(200, 200).apply { topMargin = 300 })
            decor.addView(screen, FrameLayout.LayoutParams(720, 1280))
            decor.measure(exactly(720), exactly(1280))
            decor.layout(0, 0, 720, 1280)
            val routes = RouteResolver { RouteKey("home", Confidence.High, screen) }
            val names = AndroidResourceNames(context.resources)
            input = SceneInventoryBuilder(names, routes, AnchorResolver(names, routes))
                .build(decor, RouteKey("home", Confidence.High, screen))
                ?.toJson()
        }
        return checkNotNull(input) { "expected a scene inventory" }
    }

    private fun exactly(px: Int) = View.MeasureSpec.makeMeasureSpec(px, View.MeasureSpec.EXACTLY)

    private fun submit(json: String): EngineResponse = transport.submit(json.toByteArray(Charsets.UTF_8))

    private fun assertOk(response: EngineResponse) = assertEquals(response.text(), EngineStatus.OK, response.status)
}
