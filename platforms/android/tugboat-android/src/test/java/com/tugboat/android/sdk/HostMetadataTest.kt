package com.tugboat.android.sdk

import com.tugboat.android.AppInfo
import com.tugboat.android.CollectorConfig
import com.tugboat.android.TugboatConfig
import com.tugboat.android.views.input.GestureConfig
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import java.util.Locale

/**
 * Pins what the host gives the engine for `session_start`: every field the
 * collector requires (native SDK note sections 7 and 9). The engine's own
 * output is pinned by the instrumented `CollectorContractTest`.
 */
@RunWith(RobolectricTestRunner::class)
class HostMetadataTest {
    private val app = AppInfo("Sample", "1.2.3", "45", "com.example.sample", "install-1")
    private val device = DeviceSnapshot(
        id = "UP1A.231005.007",
        manufacturer = "Google",
        model = "sdk_gphone64_arm64",
        osVersion = "14",
        screenWidthDp = 411.4,
        screenHeightDp = 914.3,
        density = 2.625,
        densityDpi = 420,
        locale = Locale.forLanguageTag("pt-Latn-PT"),
        timezone = "Europe/Lisbon",
    )

    @Test
    fun hostCarriesEveryRequiredSessionStartField() {
        val host = HostMetadata(app, device).hostJson()

        val appJson = host.getJSONObject("app")
        assertEquals("1.2.3", appJson.getString("version"))
        assertEquals("45", appJson.getString("buildNumber"))
        assertEquals(setOf("name", "version", "buildNumber", "installationId", "appId"), appJson.keySet())
        val deviceJson = host.getJSONObject("device")
        assertEquals("android", deviceJson.getString("platform"))
        assertEquals(411.4, deviceJson.getJSONObject("screenSize").getDouble("width"), 0.0)
        assertEquals(2.625, deviceJson.getDouble("screenDensity"), 0.0)
        assertEquals(420, deviceJson.getInt("screenDpi"))
        assertEquals(2.625, deviceJson.getDouble("screenPixelDensity"), 0.0)
        assertEquals("10.0.2.2", host.getJSONObject("ip").getString("ip"))
        assertEquals(
            JSONObject().put("language", "pt").put("country", "PT").put("timezone", "Europe/Lisbon").toString(),
            host.getJSONObject("locale").toString(),
        )
    }

    @Test
    fun theSessionLocaleIsTheLocaleInfoShape() {
        val locale = HostMetadata(app, device).sessionLocaleJson()
        assertEquals("""{"language":"pt","country":"PT","script":"Latn","tag":"pt-Latn-PT"}""", locale.toString())
    }

    @Test
    fun completeMetadataHasNothingMissing() {
        assertTrue(HostMetadata(app, device).missingFields().isEmpty())
    }

    @Test
    fun blankOrZeroFieldsAreReportedByPath() {
        val missing = HostMetadata(
            app.copy(version = "", buildNumber = " "),
            device.copy(id = "", screenWidthDp = 0.0, density = Double.NaN, densityDpi = 0),
        ).missingFields()

        assertEquals(
            listOf(
                "app.version", "app.buildNumber", "device.id", "device.screenSize.width",
                "device.screenDensity", "device.screenDpi",
            ),
            missing,
        )
    }

    @Test
    fun engineConfigureSetsTheSdkGroups() {
        val config = TugboatConfig(
            collector = CollectorConfig("http://10.0.2.2:3000", "key"),
            app = app,
            captureFocusChanges = true,
            captureSystemInput = true,
        )
        val gesture = GestureConfig(touchSlop = 8.0, panSlop = 16.0, scaleSlop = 16.0)

        val configure = EngineConfiguration.build(config, HostMetadata(app, device), gesture)

        assertEquals(
            setOf("host", "limits", "gesture", "capture", "collector", "capabilities"),
            configure.keySet(),
        )
        assertEquals(gesture.toEngineJson().toString(), configure.getJSONObject("gesture").toString())
        assertEquals(5000, configure.getJSONObject("capture").getInt("answerTimeoutMs"))
        assertTrue(configure.getJSONObject("collector").getBoolean("enabled"))
        assertEquals(
            """{"focusChanges":true,"systemInput":true,"nativeSceneInventory":false}""",
            configure.getJSONObject("capabilities").toString(),
        )
        assertEquals("""{"maxEvents":5000,"maxFrames":500,"maxScrollSamples":200}""", configure.getJSONObject("limits").toString())
    }

    @Test
    fun sessionStartCarriesViewportPlatformEpochAndLocale() {
        val start = JSONObject(SessionMessages.sessionStart(device, HostMetadata(app, device), sessionEpoch = 2))

        assertEquals(setOf("viewport", "platform", "sessionEpoch", "locale"), start.keySet())
        assertEquals(914.3, start.getJSONObject("viewport").getDouble("height"), 0.0)
        assertEquals("android", start.getString("platform"))
        assertEquals(2, start.getInt("sessionEpoch"))
    }

    private fun JSONObject.keySet(): Set<String> = keys().asSequence().toSet()
}
