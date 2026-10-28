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
                ),
            ),
            effect,
        )
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
