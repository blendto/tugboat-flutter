package com.tugboat.android.sdk

import android.app.Activity
import android.app.Application
import android.os.Looper
import android.view.Window
import com.tugboat.android.AppInfo
import com.tugboat.android.CollectorConfig
import com.tugboat.android.Tugboat
import com.tugboat.android.TugboatConfig
import com.tugboat.android.host.FakeEngineTransport
import org.junit.Assert.assertEquals
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.Shadows.shadowOf

/** [TugboatConfig.enabled] = false installs nothing and leaves the host unchanged. */
@RunWith(RobolectricTestRunner::class)
class TugboatKillSwitchTest {
    private val application = RuntimeEnvironment.getApplication() as Application
    private val config = TugboatConfig(
        collector = CollectorConfig("http://10.0.2.2:3000", "key"),
        app = AppInfo("Sample", "1.0.0", "1", "com.example.sample", "install-1"),
        enabled = false,
    )

    @Test
    fun disabledConfigDoesNotOpenTheEngine() {
        var opened = false
        val runtime = TugboatRuntime.start(
            application,
            config,
            sessionEpoch = 0,
            openTransport = {
                opened = true
                FakeEngineTransport()
            },
        )
        assertTrue(runtime == null && !opened)
    }

    @Test
    fun disabledStartRegistersNoActivityLifecycleCallbacks() {
        val before = activityLifecycleCallbackCount(application)
        Tugboat.start(application, config)
        Tugboat.stop()
        assertEquals(before, activityLifecycleCallbackCount(application))
    }

    @Test
    fun enabledStartRegistersActivityLifecycleCallbacks() {
        val before = activityLifecycleCallbackCount(application)
        val runtime = TugboatRuntime.start(
            application,
            config.copy(enabled = true),
            sessionEpoch = 0,
            openTransport = { FakeEngineTransport() },
            stopSequence = StopSequence(maxDrainMs = 10),
        )
        assertTrue(runtime != null)
        assertTrue(activityLifecycleCallbackCount(application) > before)
        runtime!!.stop()
    }

    @Test
    fun disabledStartLeavesTheWindowCallbackUntouched() {
        val controller = Robolectric.buildActivity(Activity::class.java).create().start().resume()
        val window: Window = controller.get().window
        val original = window.callback

        Tugboat.start(application, config)
        shadowOf(Looper.getMainLooper()).idle()

        assertSame(original, window.callback)
        Tugboat.stop()
    }

    private fun activityLifecycleCallbackCount(application: Application): Int {
        val field = Application::class.java.getDeclaredField("mActivityLifecycleCallbacks")
        field.isAccessible = true
        @Suppress("UNCHECKED_CAST")
        return (field.get(application) as? ArrayList<*>)?.size ?: 0
    }

}
