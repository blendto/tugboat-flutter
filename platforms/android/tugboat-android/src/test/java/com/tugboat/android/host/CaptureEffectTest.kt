package com.tugboat.android.host

import android.os.Handler
import android.os.Looper
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf

/** `capture.request` effects: parsed, routed to the capture sink, and never started by `engine.dispose`. */
@RunWith(RobolectricTestRunner::class)
class CaptureEffectTest {
    private val request =
        """{"type":"capture.request","requestId":"capture-3","trigger":"route","force":false,"requireFreshPaint":true,""" +
            """"dropWhenBusy":false,"notBeforeMonoUs":5000,"context":{"routeEpoch":2,"navigatorId":"nav-1",""" +
            """"routeInstanceId":"route-2","boundaryGeneration":1},"dHashBaseline":{"dHash":"00ff","structureSignature":"ab"},"scale":0.8}"""

    @Test
    fun parsesEveryFieldTheHostActsOn() {
        val effect = EffectParser.parse("""{"effects":[$request]}""").single()

        assertEquals(
            Effect.CaptureRequest(
                CaptureRequestEffect(
                    requestId = "capture-3",
                    force = false,
                    scale = 0.8,
                    dHashBaseline = DHashBaseline("00ff", "ab"),
                    trigger = "route",
                ),
            ),
            effect,
        )
    }

    @Test
    fun theSceneTriggerIsTheInteractionLabelElseTheCaptureTrigger() {
        fun triggerOf(trigger: String, label: String? = null): String {
            val extra = label?.let { ""","inventoryTrigger":"$it"""" } ?: ""
            val json = """{"type":"capture.request","requestId":"c","trigger":"$trigger","force":true,"requireFreshPaint":true,""" +
                """"dropWhenBusy":false,"notBeforeMonoUs":0,"context":{"routeEpoch":0,"boundaryGeneration":0}$extra}"""
            return (EffectParser.parse("""{"effects":[$json]}""").single() as Effect.CaptureRequest).request.sceneTrigger
        }

        assertEquals("tap", triggerOf("interaction", "tap"))
        assertEquals("scroll", triggerOf("interaction", "scroll"))
        assertEquals("gesture", triggerOf("interaction", "gesture"))
        assertEquals("resume", triggerOf("lifecycle"))
        assertEquals("initial", triggerOf("initial"))
        assertEquals("route", triggerOf("route"))
        assertEquals("manual", triggerOf("manual"))
    }

    @Test
    fun parsesTheSceneWatchAndSampleEffects() {
        val effects = EffectParser.parse(
            """{"effects":[{"type":"scene.watch","armed":true},{"type":"scene.sample"},{"type":"scene.watch","armed":false}]}""",
        )

        assertEquals(listOf(Effect.SceneWatch(true), Effect.SceneSample, Effect.SceneWatch(false)), effects)
    }

    @Test
    fun theDispatcherRoutesTheSceneEffectsToTheWatchSink() {
        val calls = ArrayList<String>()
        val sink = object : SceneWatchSink {
            override fun onSceneWatch(armed: Boolean) {
                calls += "watch:$armed"
            }

            override fun onSceneSample() {
                calls += "sample"
            }
        }
        val dispatcher = EffectDispatcher(
            timers = TimerExecutor(Handler(Looper.getMainLooper())) {},
            http = object : HttpSender {
                override fun send(request: HttpRequest, onResult: (TransportOutcome) -> Unit) = Unit
            },
            frames = FrameHandleTable(),
            post = { _, _ -> },
            captures = CaptureRequestSink.NONE,
            scenes = sink,
        )

        EffectParser.parse(
            """{"effects":[{"type":"scene.watch","armed":true},{"type":"scene.sample"},{"type":"scene.watch","armed":false}]}""",
        ).forEach(dispatcher::dispatch)

        assertEquals(listOf("watch:true", "sample", "watch:false"), calls)
    }

    @Test
    fun aForcedRequestHasNoBaselineAndDefaultsItsScale() {
        val forced = """{"type":"capture.request","requestId":"capture-1","trigger":"initial","force":true,""" +
            """"requireFreshPaint":true,"dropWhenBusy":false,"notBeforeMonoUs":0,"context":{"routeEpoch":0,"boundaryGeneration":0}}"""
        val parsed = (EffectParser.parse("""{"effects":[$forced]}""").single() as Effect.CaptureRequest).request

        assertEquals(null, parsed.dHashBaseline)
        assertEquals(1.0, parsed.scale, 0.0)
        assertTrue(parsed.force)
    }

    @Test
    fun requestsGoToTheSinkAndDisposeStartsNone() {
        val looper = shadowOf(Looper.getMainLooper())
        val received = ArrayList<String>()
        val transport = FakeEngineTransport(ok(request))
        val host = EngineHost(
            transport = transport,
            handler = Handler(Looper.getMainLooper()),
            http = FakeHttpSender(),
            frames = FrameHandleTable(),
            clock = FakeClock(),
            captures = CaptureRequestSink { received += it.requestId },
        )

        host.post("session.start", "{}", HostTime(1, 1))
        looper.idle()
        assertEquals(listOf("capture-3"), received)

        transport.enqueue(ok(request.replace("capture-3", "capture-4")))
        host.close()
        looper.idle()
        assertEquals("engine.dispose effects start no capture", listOf("capture-3"), received)
    }
}
