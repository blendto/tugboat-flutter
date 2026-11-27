package com.tugboat.android.sdk

import android.app.Application
import com.tugboat.android.AppInfo
import com.tugboat.android.CollectorConfig
import com.tugboat.android.TugboatConfig
import com.tugboat.android.host.FakeEngineTransport
import com.tugboat.android.views.navigation.NavigationObservation
import java.io.File
import java.util.concurrent.CountDownLatch
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment

/**
 * BLE-618: the installation id file is read or written off the main thread
 * (on the engine thread), `start` does not wait for it, and the id is in
 * place in `engine.configure` before `session.start`, so before the first
 * `session_start` is sent. A refused start never touches the file.
 */
@RunWith(RobolectricTestRunner::class)
class InstallationIdOrderingTest {
    @get:Rule
    val folder = TemporaryFolder()

    private val application = RuntimeEnvironment.getApplication() as Application

    private fun config(app: AppInfo = AppInfo("Sample", "1.0.0", "1", "com.example.sample")) = TugboatConfig(
        collector = CollectorConfig("http://10.0.2.2:3000", "pmk_blend-app-dev-secret"),
        app = app,
    )

    @Before
    fun resetNavigation() = NavigationObservation.resetForTests()

    @After
    fun restoreStore() = InstallationIds.setStoreForTesting(null)

    private fun types(transport: FakeEngineTransport) = transport.submitted.map { JSONObject(it).getString("type") }

    private fun awaitUntil(condition: () -> Boolean) {
        val deadline = System.currentTimeMillis() + 5_000
        while (!condition() && System.currentTimeMillis() < deadline) Thread.sleep(10)
        assertTrue("timed out", condition())
    }

    @Test
    fun startDoesNotWaitForTheDiskAndTheIdIsInConfigureBeforeSessionStart() {
        val gate = CountDownLatch(1)
        var diskThread: Thread? = null
        InstallationIds.setStoreForTesting(
            InstallationIdStore(directory = {
                diskThread = Thread.currentThread()
                gate.await()
                folder.root
            }),
        )
        val transport = FakeEngineTransport()
        val runtime = TugboatRuntime.start(
            application,
            config(),
            sessionEpoch = 0,
            openTransport = { transport },
            stopSequence = StopSequence(maxDrainMs = 10),
        )
        // `start` returned while the disk is still "slow": it never blocked on it, and nothing has reached the engine.
        assertNotNull(runtime)
        assertTrue(transport.submitted.isEmpty())

        gate.countDown()
        awaitUntil { "session.start" in types(transport) }
        assertFalse("the file was read on the main thread", diskThread === Thread.currentThread())

        val kinds = types(transport)
        assertTrue(kinds.indexOf("engine.configure") < kinds.indexOf("session.start"))
        val configure = JSONObject(transport.submitted.first { it.contains("engine.configure") })
        val id = configure.getJSONObject("input").getJSONObject("host").getJSONObject("app").getString("installationId")
        assertTrue(id, id.isNotBlank())
        assertEquals(id, File(folder.root, "tugboat/installation_id").readText())
        runtime!!.stop()
    }

    @Test
    fun aHostIdWinsAndTheFileIsNeverCreated() {
        InstallationIds.setStoreForTesting(InstallationIdStore(directory = { folder.root }))
        val transport = FakeEngineTransport()
        val runtime = TugboatRuntime.start(
            application,
            config(AppInfo("Sample", "1.0.0", "1", "com.example.sample", "host-id")),
            sessionEpoch = 0,
            openTransport = { transport },
            stopSequence = StopSequence(maxDrainMs = 10),
        )
        awaitUntil { "session.start" in types(transport) }
        val configure = JSONObject(transport.submitted.first { it.contains("engine.configure") })
        assertEquals(
            "host-id",
            configure.getJSONObject("input").getJSONObject("host").getJSONObject("app").getString("installationId"),
        )
        assertFalse(File(folder.root, "tugboat/installation_id").exists())
        runtime!!.stop()
    }

    @Test
    fun aRefusedStartNeverTouchesTheFile() {
        InstallationIds.setStoreForTesting(InstallationIdStore(directory = { folder.root }))
        val refused = TugboatRuntime.start(
            application,
            config(AppInfo("Sample", "", "1", "com.example.sample")), // no version: refused
            sessionEpoch = 0,
            openTransport = { FakeEngineTransport() },
        )
        assertEquals(null, refused)
        assertFalse(File(folder.root, "tugboat").exists())
    }
}
