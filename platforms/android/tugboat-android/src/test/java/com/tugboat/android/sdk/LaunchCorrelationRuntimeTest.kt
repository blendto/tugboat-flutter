package com.tugboat.android.sdk

import android.app.Activity
import android.app.Application
import android.content.Intent
import android.os.Bundle
import com.tugboat.android.AppInfo
import com.tugboat.android.CollectorConfig
import com.tugboat.android.TugboatConfig
import com.tugboat.android.host.FakeEngineTransport
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config
import org.robolectric.shadows.ShadowLog

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [28])
class LaunchCorrelationRuntimeTest {
    private val application = RuntimeEnvironment.getApplication() as Application
    private val config = TugboatConfig(
        collector = CollectorConfig("http://10.0.2.2:3000", "pmk_blend-app-dev-secret"),
        app = AppInfo("Sample", "1.0.0", "1", "com.example.sample", "install-1"),
    )

    @Before
    fun resetLatch() {
        LaunchCorrelation.resetForTests()
        ShadowLog.clear()
    }

    @Test
    fun launchCaptureSessionIdMatchesSessionStartAt() {
        val transport = FakeEngineTransport()
        val runtime = TugboatRuntime.start(
            application,
            config,
            sessionEpoch = 0,
            openTransport = { transport },
            stopSequence = StopSequence(maxDrainMs = 10),
        )
        assertNotNull(runtime)

        Robolectric.buildActivity(
            Activity::class.java,
            Intent().putExtras(Bundle().apply { putString(LaunchExtraKeys.EMIT_SCENE_INVENTORY, "1") }),
        ).create().start().resume()

        val sessionStart = transport.submitted
            .map { JSONObject(it) }
            .first { it.getString("type") == "session.start" }
        val wallUs = sessionStart.getJSONObject("at").getLong("wallUs")

        val launchLine = ShadowLog.getLogsForTag(LaunchCorrelation.TAG)
            .map { it.msg }
            .first { it.contains("TUGBOAT_LAUNCH") }
        val launchJson = JSONObject(launchLine.removePrefix("TUGBOAT_LAUNCH ").trim())
        assertEquals("session-$wallUs", launchJson.getString("captureSessionId"))

        runtime!!.stop()
    }
}
