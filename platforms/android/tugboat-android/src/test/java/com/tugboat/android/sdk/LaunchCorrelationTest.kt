package com.tugboat.android.sdk

import android.app.Activity
import android.content.Intent
import android.os.Bundle
import com.tugboat.android.TugboatLifecycleState
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.shadows.ShadowLooper
import java.util.concurrent.TimeUnit

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [28])
class LaunchCorrelationTest {
    private val lines = mutableListOf<String>()

    @Before
    fun resetLatch() {
        LaunchCorrelation.resetForTests()
        lines.clear()
    }

    private fun correlation(
        sessionWallUs: Long = 1_781_827_200_000_000L,
        lifecycle: LifecycleSnapshot = LifecycleSnapshot(TugboatLifecycleState.ACTIVE, null),
    ) = LaunchCorrelation(
        sessionWallUs = sessionWallUs,
        lifecycle = { lifecycle },
        emit = lines::add,
    )

    @Test
    fun noExtrasEmitsNoLines() {
        val activity = Robolectric.buildActivity(Activity::class.java).setup().get()
        correlation().onActivityResumed(activity)
        assertTrue(lines.isEmpty())
    }

    @Test
    fun launchExtrasEmitLaunchOnceWithSessionIdAndFlags() {
        val activity = activityWithExtras(
            Bundle().apply {
                putString(LaunchExtraKeys.EMIT_SCENE_INVENTORY, "1")
                putString(LaunchExtraKeys.ACCEPT_ACTION_CONTEXT, "yes")
                putString(LaunchExtraKeys.AUTOMATION_RUN_ID, "probe-1")
            },
        )
        correlation().onActivityResumed(activity)
        assertEquals(1, lines.size)
        assertTrue(lines[0].startsWith("TUGBOAT_LAUNCH "))
        val json = JSONObject(lines[0].removePrefix("TUGBOAT_LAUNCH "))
        assertTrue(json.getBoolean("captureRequested"))
        assertTrue(json.getBoolean("emitSceneInventory"))
        assertTrue(json.getBoolean("acceptActionContext"))
        assertEquals("probe-1", json.getString("automationRunId"))
        assertEquals("session-1781827200000000", json.getString("captureSessionId"))
    }

    @Test
    fun resumeWithoutExtrasThenWithExtrasLogsOnce() {
        val plain = Robolectric.buildActivity(Activity::class.java).setup().get()
        val withExtras = activityWithExtras(
            Bundle().apply { putString(LaunchExtraKeys.EMIT_SCENE_INVENTORY, "1") },
        )
        val correlation = correlation()
        correlation.onActivityResumed(plain)
        correlation.onActivityResumed(withExtras)
        assertEquals(1, lines.size)
        assertTrue(lines[0].startsWith("TUGBOAT_LAUNCH "))
    }

    @Test
    fun stopStartAndResumeWithExtrasLogsNoSecondLaunch() {
        val activity = activityWithExtras(
            Bundle().apply { putString(LaunchExtraKeys.ACCEPT_ACTION_CONTEXT, "true") },
        )
        val first = correlation(sessionWallUs = 100)
        first.onActivityResumed(activity)
        first.stop()
        val second = correlation(sessionWallUs = 200)
        second.onActivityResumed(activity)
        assertEquals(1, lines.size)
        assertTrue(lines[0].contains("session-100"))
    }

    @Test
    fun wrongExtraTypesTurnFlagsOffWithoutCrashing() {
        val activity = activityWithExtras(
            Bundle().apply {
                putStringArray(LaunchExtraKeys.EMIT_SCENE_INVENTORY, arrayOf("1"))
                putBoolean(LaunchExtraKeys.ACCEPT_ACTION_CONTEXT, false)
            },
        )
        correlation().onActivityResumed(activity)
        assertTrue(lines.isEmpty())
    }

    @Test
    fun automationRunIdWithControlCharactersStillParsesAsJson() {
        val runId = "run\u0001\"x"
        val activity = activityWithExtras(
            Bundle().apply {
                putString(LaunchExtraKeys.EMIT_SCENE_INVENTORY, "1")
                putString(LaunchExtraKeys.AUTOMATION_RUN_ID, runId)
            },
        )
        correlation().onActivityResumed(activity)
        val json = JSONObject(lines[0].removePrefix("TUGBOAT_LAUNCH "))
        assertEquals(runId, json.getString("automationRunId"))
    }

    @Test
    fun healthFiresAfterTenSecondsWithActiveLifecycle() {
        val activity = activityWithExtras(
            Bundle().apply { putBoolean(LaunchExtraKeys.EMIT_SCENE_INVENTORY, true) },
        )
        val correlation = correlation()
        correlation.onActivityResumed(activity)
        ShadowLooper.shadowMainLooper().idleFor(10, TimeUnit.SECONDS)
        assertEquals(2, lines.size)
        assertTrue(lines[1].startsWith("TUGBOAT_HEALTH "))
        val json = JSONObject(lines[1].removePrefix("TUGBOAT_HEALTH "))
        assertEquals("active", json.getString("lifecycle"))
        assertEquals("session-1781827200000000", json.getString("captureSessionId"))
        assertTrue(SESSION_ID_REGEX.matches(json.getString("captureSessionId")))
    }

    @Test
    fun healthIsDormantWithoutSessionIdWhenDormant() {
        val activity = activityWithExtras(
            Bundle().apply { putString(LaunchExtraKeys.EMIT_SCENE_INVENTORY, "1") },
        )
        val correlation = correlation(lifecycle = LifecycleSnapshot.DORMANT)
        correlation.onActivityResumed(activity)
        ShadowLooper.shadowMainLooper().idleFor(10, TimeUnit.SECONDS)
        val json = JSONObject(lines[1].removePrefix("TUGBOAT_HEALTH "))
        assertEquals("dormant", json.getString("lifecycle"))
        assertFalse(json.has("captureSessionId"))
        assertFalse(json.has("activationRequestId"))
    }

    @Test
    fun healthCarriesTheActivationRequestIdWhileActivated() {
        val activity = activityWithExtras(
            Bundle().apply { putString(LaunchExtraKeys.EMIT_SCENE_INVENTORY, "1") },
        )
        val correlation = correlation(lifecycle = LifecycleSnapshot(TugboatLifecycleState.ACTIVE, "act-7"))
        correlation.onActivityResumed(activity)
        ShadowLooper.shadowMainLooper().idleFor(10, TimeUnit.SECONDS)
        val json = JSONObject(lines[1].removePrefix("TUGBOAT_HEALTH "))
        assertEquals("active", json.getString("lifecycle"))
        assertEquals("act-7", json.getString("activationRequestId"))
        assertEquals("session-1781827200000000", json.getString("captureSessionId"))
    }

    @Test
    fun healthUsesFlutterLifecycleNames() {
        val names = TugboatLifecycleState.values().map {
            JSONObject(LaunchOptions.healthJson(LifecycleSnapshot(it, null), 1)).getString("lifecycle")
        }
        assertEquals(listOf("dormant", "starting", "active", "stopping"), names)
        val stopping = JSONObject(LaunchOptions.healthJson(LifecycleSnapshot(TugboatLifecycleState.STOPPING, null), 1))
        assertEquals("session-1", stopping.getString("captureSessionId"))
    }

    @Test
    fun stopCancelsHealth() {
        val activity = activityWithExtras(
            Bundle().apply { putString(LaunchExtraKeys.ACCEPT_ACTION_CONTEXT, "true") },
        )
        val correlation = correlation()
        correlation.onActivityResumed(activity)
        correlation.stop()
        ShadowLooper.idleMainLooper()
        assertEquals(1, lines.size)
    }

    @Test
    fun automationRunIdAloneDoesNotEmit() {
        val activity = activityWithExtras(
            Bundle().apply { putString(LaunchExtraKeys.AUTOMATION_RUN_ID, "only-run") },
        )
        correlation().onActivityResumed(activity)
        assertTrue(lines.isEmpty())
    }

    @Test
    fun parseBoolMatchesDart() {
        assertTrue(TugboatLaunchParsers.parseBool("1"))
        assertTrue(TugboatLaunchParsers.parseBool(" True "))
        assertFalse(TugboatLaunchParsers.parseBool(null))
        assertFalse(TugboatLaunchParsers.parseBool("0"))
    }

    private fun activityWithExtras(extras: Bundle): Activity {
        val intent = Intent().putExtras(extras)
        return Robolectric.buildActivity(Activity::class.java, intent).setup().get()
    }

    companion object {
        private val SESSION_ID_REGEX = Regex("^session-[0-9]+$")
    }
}
