package com.tugboat.android.sdk

import com.tugboat.android.host.TransportOutcome
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * `SessionEndWatcher.isFinal` repeats the engine's delivery rule (when a
 * collector answer is final) so `stop()` knows when `session_end` settled.
 * This pins the copy against the engine's source and its conformance
 * fixture: if either changes, this fails and the watcher must follow.
 */
class EngineRetryRuleTest {
    private val engine = File(System.getProperty("tugboat.engineSources") ?: "../../../core/session-engine")

    @Test
    fun theEngineStillClassifiesStatusesThisWay() {
        val classify = File(engine, "src/transport.cpp").readText().substringAfter("Verdict classify(")
            .substringBefore("\n}\n")
        assertTrue(classify, "if (status == 202) {\n    return Verdict::kAccepted;" in classify)
        assertTrue(classify, "if (status == 408 || status == 429 || status >= 500) {\n    return Verdict::kRetry;" in classify)
        assertTrue(classify, "if (result.outcome != TransportOutcome::kHttp) {\n    return Verdict::kRetry;" in classify)
        assertTrue(classify, "return Verdict::kDrop;" in classify)

        val fixture = File(engine, "../../conformance/engine/scenario/delivery-status-classification.json").readText()
        assertTrue(
            "fixture description",
            "Only HTTP 202 is acceptance (C8 kept): 200, 201, 204, and every other 4xx drop the batch for good; " +
                "408, 429, 5xx, a transport error, and a timeout queue it for retry." in fixture,
        )
    }

    @Test
    fun theWatcherMatchesThatRule() {
        val final = listOf(200, 201, 202, 204, 302, 400, 401, 404, 413, 499)
        val retried = listOf(408, 429, 500, 502, 503, 599)
        final.forEach { assertTrue("$it", SessionEndWatcher.isFinal(TransportOutcome.Http(it, ""))) }
        retried.forEach { assertEquals("$it", false, SessionEndWatcher.isFinal(TransportOutcome.Http(it, ""))) }
        assertEquals(false, SessionEndWatcher.isFinal(TransportOutcome.Error))
        assertEquals(false, SessionEndWatcher.isFinal(TransportOutcome.Timeout))
    }
}
