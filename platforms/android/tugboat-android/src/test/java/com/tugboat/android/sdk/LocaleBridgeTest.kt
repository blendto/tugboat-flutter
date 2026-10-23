package com.tugboat.android.sdk

import android.app.Application
import android.content.res.Configuration
import android.os.LocaleList
import android.os.Looper
import com.tugboat.android.AppInfo
import com.tugboat.android.CollectorConfig
import com.tugboat.android.TugboatConfig
import com.tugboat.android.host.FakeEngineTransport
import java.util.Locale
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.Shadows.shadowOf

@RunWith(RobolectricTestRunner::class)
class LocaleBridgeTest {
    private val application = RuntimeEnvironment.getApplication() as Application
    private val config = TugboatConfig(
        collector = CollectorConfig("http://10.0.2.2:3000", "key"),
        app = AppInfo("Sample", "1.0.0", "1", "com.example.sample", "install-1"),
    )

    @Test
    fun primaryLocaleChangePostsLocaleSetDeduped() {
        val transport = FakeEngineTransport()
        val runtime = TugboatRuntime.start(
            application,
            config,
            sessionEpoch = 0,
            openTransport = { transport },
            stopSequence = StopSequence(maxDrainMs = 10),
        )
        assertNotNull(runtime)

        val initial = DeviceSnapshot.read(application).locale
        val target = if (initial.language == "ja") Locale.FRANCE else Locale.JAPAN
        val changed = Configuration(application.resources.configuration)
        changed.setLocales(LocaleList(target))
        application.onConfigurationChanged(changed)
        awaitLocaleSet(transport)

        application.onConfigurationChanged(changed)
        shadowOf(Looper.getMainLooper()).idle()

        val localeSets = transport.submitted
            .map { JSONObject(it) }
            .filter { it.getString("type") == SessionMessages.LOCALE_SET }
        assertEquals(1, localeSets.size)
        val locale = localeSets.single().getJSONObject("input").getJSONObject("locale")
        assertEquals(target.language, locale.getString("language"))
        assertEquals(target.toLanguageTag(), locale.getString("tag"))

        runtime!!.stop()
    }

    @Test
    fun localeObserverUnregistersOnStop() {
        val transport = FakeEngineTransport()
        val runtime = TugboatRuntime.start(application, config, sessionEpoch = 0, openTransport = { transport })!!
        runtime.stop()

        val frConfig = Configuration(application.resources.configuration)
        frConfig.setLocales(LocaleList(Locale.GERMANY))
        application.onConfigurationChanged(frConfig)
        shadowOf(Looper.getMainLooper()).idle()

        assertFalse(
            transport.submitted.map { JSONObject(it).getString("type") }.contains(SessionMessages.LOCALE_SET),
        )
    }

    private fun awaitLocaleSet(transport: FakeEngineTransport) {
        val deadline = System.currentTimeMillis() + 5_000
        while (System.currentTimeMillis() < deadline) {
            shadowOf(Looper.getMainLooper()).idle()
            if (transport.submitted.any { JSONObject(it).getString("type") == SessionMessages.LOCALE_SET }) {
                return
            }
            Thread.sleep(10)
        }
        assertTrue(
            "timed out waiting for locale.set",
            transport.submitted.any { JSONObject(it).getString("type") == SessionMessages.LOCALE_SET },
        )
    }
}
