package com.tugboat.android.views

import com.tugboat.android.host.HostTime
import com.tugboat.android.views.facts.FactBatcher
import com.tugboat.android.views.facts.ViewsFact
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner

@RunWith(RobolectricTestRunner::class)
class FactBatcherTest {
    private val sink = RecordingSink()
    private val frames = ManualFrames()
    private val batcher = FactBatcher(sink, frames)

    @Test
    fun factsOfOneFrameLeaveAsOneBatchInOrderWithTheirOwnTimes() {
        batcher.add(fact("a", 10))
        batcher.add(fact("b", 20))
        assertTrue(sink.batches.isEmpty())
        frames.runFrame()
        batcher.add(fact("c", 30))
        frames.runFrame()

        assertEquals(2, sink.batches.size)
        assertEquals(listOf("a", "b"), sink.batches[0].map { it.type })
        assertEquals(listOf(10L, 20L), sink.batches[0].map { it.at!!.monoUs })
        assertEquals(listOf("c"), sink.batches[1].map { it.type })
    }

    @Test
    fun frameHooksRunFirstAndTheirFactsJoinTheBatch() {
        batcher.onFrame { batcher.add(fact("hook", 5)) }
        batcher.add(fact("a", 10))
        frames.runFrame()
        assertEquals(listOf("a", "hook"), sink.batches.single().map { it.type })
    }

    @Test
    fun aFailingHookDoesNotStopTheBatch() {
        batcher.onFrame { throw IllegalStateException("hook bug") }
        batcher.add(fact("a", 10))
        frames.runFrame()
        assertEquals(listOf("a"), sink.batches.single().map { it.type })
    }

    @Test
    fun oneFrameRequestPerFrame() {
        batcher.add(fact("a", 1))
        batcher.add(fact("b", 2))
        batcher.requestFrame()
        frames.runFrame()
        assertTrue(!frames.hasPending)
    }

    private fun fact(type: String, monoUs: Long) = ViewsFact(type, JSONObject(), HostTime(monoUs, monoUs))
}
