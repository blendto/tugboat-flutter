package com.tugboat.android.outbox

import android.os.Looper
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleRegistry
import androidx.lifecycle.ProcessLifecycleOwner
import com.tugboat.android.AppInfo
import com.tugboat.android.CollectorConfig
import com.tugboat.android.Tugboat
import com.tugboat.android.TugboatConfig
import com.tugboat.android.engine.EngineTransport
import com.tugboat.android.host.FakeEngineTransport
import com.tugboat.android.host.ok
import com.tugboat.android.host.FakeHttpSender
import com.tugboat.android.host.LocalHttpServer
import com.tugboat.android.outbox.OutboxFixtures.entryDirs
import com.tugboat.android.outbox.OutboxFixtures.lifecycle
import com.tugboat.android.sdk.StopSequence
import com.tugboat.android.sdk.TugboatRuntime
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.Shadows.shadowOf
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/**
 * The outbox through the facade: wipe triggers (agreed by Chinmay on
 * 2026-10-27), no network while dormant, and the background flush.
 */
@RunWith(RobolectricTestRunner::class)
class OutboxLifecycleTest {
    private val application = RuntimeEnvironment.getApplication()
    /** Where the process outbox lives, as `Outboxes.at` resolves it. */
    private val root = java.io.File(application.noBackupFilesDir, "tugboat/outbox")
    private val server = LocalHttpServer()
    private val transports = CopyOnWriteArrayList<FakeEngineTransport>()
    private val config = TugboatConfig(
        collector = CollectorConfig("http://127.0.0.1:${server.port}", "pmk_key"),
        app = AppInfo("Sample", "1.0.0", "1", "com.example.app", "install-1"),
        durableOutbox = true,
    )
    private val inputs = OutboxIdentityInputs(config.collector.baseUrl, config.app.appId, config.collector.apiKey)
    /** The process outbox (created by the first start). */
    private val process: Outbox
        get() = Outboxes.at(application)

    @Before
    fun setUp() {
        Tugboat.resetForTests()
        root.deleteRecursively()
        Tugboat.openTransportForTesting = { FakeEngineTransport().also(transports::add) }
    }

    @After
    fun tearDown() {
        Tugboat.stop()
        idle()
        Tugboat.resetForTests()
        server.close()
        root.deleteRecursively()
    }

    /** An earlier launch (process A) sent [request] and died unanswered. */
    private fun keptByAnEarlierLaunch(
        request: com.tugboat.android.host.HttpRequest = lifecycle(),
        identity: OutboxIdentityInputs = inputs,
    ) {
        val a = OutboxFixtures.outbox(root, "epoch-a")
        OutboxSender(FakeHttpSender(), a, identity, "0.1.0", frameBytes = { null }).send(request) {}
        assertTrue(a.awaitQueued(5_000))
    }

    @Test
    fun aStartWithTheOutboxOffDeletesWhatAnEarlierLaunchKept() {
        keptByAnEarlierLaunch()

        Tugboat.start(application, config.copy(durableOutbox = false))
        idle()

        assertTrue(process.awaitQueued(5_000))
        assertTrue(entryDirs(root).isEmpty())
    }

    @Test
    fun aDormantStartKeepsEntriesAndSendsNothingUntilActivateReplaysThem() {
        keptByAnEarlierLaunch()

        Tugboat.start(application, config)
        idle()
        Thread.sleep(300)
        assertTrue(process.awaitQueued(5_000))
        assertTrue("dormant: no network", server.received.isEmpty())
        assertEquals("dormant: kept", 1, entryDirs(root).size)

        Tugboat.activate("a")
        awaitUntil { server.received.isNotEmpty() }
        assertEquals("s-1/l/session_start/2026-10-27T10:00:00.000Z", server.received.single().headers["tugboat-delivery-key"])
        awaitUntil { entryDirs(root).isEmpty() }
    }

    @Test
    fun aDormantStartDeletesEntriesPastTheMaxAgeAndSendsNothing() {
        val a = OutboxFixtures.outbox(root, "epoch-a") { 1_000L }
        OutboxSender(FakeHttpSender(), a, inputs, "0.1.0", frameBytes = { null }).send(lifecycle()) {}
        assertTrue(a.awaitQueued(5_000))
        keptByAnEarlierLaunch(OutboxFixtures.events())
        assertEquals(2, entryDirs(root).size)

        Tugboat.start(application, config)
        idle()

        assertTrue(process.awaitQueued(5_000))
        assertEquals("only the fresh entry is left", 1, entryDirs(root).size)
        Thread.sleep(200)
        assertTrue("dormant: no network", server.received.isEmpty())
    }

    @Test
    fun deactivateStopsTheReplay() {
        keptByAnEarlierLaunch()
        server.reply = { LocalHttpServer.Response(503) }
        Tugboat.start(application, config)
        Tugboat.activate("a")
        awaitUntil { server.received.size == 1 }

        Tugboat.deactivate()
        idle()
        // Past the 2 s backoff the drainer had scheduled.
        Thread.sleep(3_000)

        assertEquals("no replay after deactivate", 1, server.received.size)
    }

    @Test
    fun theRuntimeReplaysOnItsOwnThreadBesideTheEngine() {
        val concurrent = LocalHttpServer(concurrent = true)
        val collector = CollectorConfig("http://127.0.0.1:${concurrent.port}", "pmk_key")
        keptByAnEarlierLaunch(identity = OutboxIdentityInputs(collector.baseUrl, config.app.appId, collector.apiKey))
        val replayArrived = CountDownLatch(1)
        val releaseReplay = CountDownLatch(1)
        val engineArrived = CountDownLatch(1)
        concurrent.reply = { request ->
            if (request.path == "/v1/sessions") {
                replayArrived.countDown()
                releaseReplay.await(30, TimeUnit.SECONDS)
            } else {
                engineArrived.countDown()
            }
            LocalHttpServer.Response(202)
        }
        val engineSend = """{"type":"http.send","requestId":"http-9","lane":"events","path":"/v1/events/batch",""" +
            """"timeoutMs":15000,"jsonBody":"{\"events\":[{\"id\":\"e-9\",\"sessionId\":\"s-2\"}]}"}"""
        // An engine whose identity.set answer is one events request.
        val transport = object : EngineTransport {
            override fun submit(message: ByteArray) =
                if (JSONObject(String(message, Charsets.UTF_8)).optString("type") == "identity.set") ok(engineSend) else ok()

            override fun close() = Unit
        }
        val runtime = TugboatRuntime.start(
            application,
            config.copy(collector = collector),
            0,
            openTransport = { transport },
            stopSequence = StopSequence(10),
        )
        try {
            assertTrue("the replay reached the collector", replayArrived.await(5, TimeUnit.SECONDS))

            runtime?.setUserId("u-1")

            assertTrue("the engine request waited behind the replay", engineArrived.await(10, TimeUnit.SECONDS))
        } finally {
            releaseReplay.countDown()
            runtime?.stop()
            concurrent.close()
        }
    }

    @Test
    fun clearPendingDataBeforeStartWipesAtTheFirstStart() {
        keptByAnEarlierLaunch()

        Tugboat.clearPendingData()
        Thread.sleep(100)
        assertEquals("no outbox yet: the request waits for start", 1, entryDirs(root).size)
        // Outbox on and dormant: only the request wipes.
        Tugboat.start(application, config)
        idle()

        assertTrue(process.awaitQueued(5_000))
        assertTrue(entryDirs(root).isEmpty())
    }

    @Test
    fun clearPendingDataWhileRunningWipesAtOnce() {
        Tugboat.start(application, config.copy(enabled = true))
        idle()
        keptByAnEarlierLaunch()

        Tugboat.clearPendingData()

        assertTrue(process.awaitQueued(5_000))
        assertTrue(entryDirs(root).isEmpty())
    }

    @Test
    fun goingToTheBackgroundFlushesAtOnceOnlyWithTheOutboxOn() {
        assertEquals(listOf("inactive", "paused", "transport.flush"), backgroundMessages(config))
        assertEquals(listOf("inactive", "paused"), backgroundMessages(config.copy(durableOutbox = false)))
    }

    /** What an `ON_STOP` posts in a session of [config]: `app.lifecycle` states, other message types. */
    private fun backgroundMessages(config: TugboatConfig): List<String> {
        val transport = FakeEngineTransport()
        val registry = ProcessLifecycleOwner.get().lifecycle as LifecycleRegistry
        registry.handleLifecycleEvent(Lifecycle.Event.ON_RESUME)
        val runtime = TugboatRuntime.start(application, config, 0, openTransport = { transport }, stopSequence = StopSequence(10))
        try {
            awaitUntil { transport.submitted.size >= 3 }
            val before = transport.submitted.size
            registry.handleLifecycleEvent(Lifecycle.Event.ON_STOP)
            Thread.sleep(200)
            idle()
            return transport.submitted.drop(before).map { submitted ->
                val message = JSONObject(submitted)
                val type = message.getString("type")
                if (type == "app.lifecycle") message.getJSONObject("input").getString("state") else type
            }
        } finally {
            runtime?.stop()
            awaitUntil { transport.closed }
        }
    }

    private fun idle() = shadowOf(Looper.getMainLooper()).idle()

    private fun awaitUntil(condition: () -> Boolean) {
        val deadline = System.currentTimeMillis() + 5_000
        while (!condition() && System.currentTimeMillis() < deadline) {
            idle()
            Thread.sleep(10)
        }
        assertTrue("timed out", condition())
    }
}
