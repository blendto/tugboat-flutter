package com.tugboat.android.host

import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import org.junit.Assert.assertEquals
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import java.time.Duration

@RunWith(RobolectricTestRunner::class)
class TimerExecutorTest {
    private val looper = shadowOf(Looper.getMainLooper())
    private val fired = mutableListOf<Pair<String, Long>>()
    private val timers = TimerExecutor(Handler(Looper.getMainLooper())) { id -> fired += id to SystemClock.uptimeMillis() }

    private fun inMs(ms: Long) = (SystemClock.uptimeMillis() + ms) * 1000

    @Test
    fun firesAtTheUptimeDeadline() {
        val due = SystemClock.uptimeMillis() + 250
        timers.schedule("flush", due * 1000)

        looper.idleFor(Duration.ofMillis(249))
        assertEquals(emptyList<Pair<String, Long>>(), fired)
        looper.idleFor(Duration.ofMillis(1))
        assertEquals(listOf("flush" to due), fired)
        assertEquals(0, timers.scheduledCount)
    }

    @Test
    fun subMillisecondDeadlinesRoundUp() {
        val dueMs = SystemClock.uptimeMillis() + 10
        timers.schedule("t", dueMs * 1000 + 1)

        looper.idleFor(Duration.ofMillis(10))
        assertEquals(emptyList<Pair<String, Long>>(), fired)
        looper.idleFor(Duration.ofMillis(1))
        assertEquals(listOf("t" to dueMs + 1), fired)
    }

    @Test
    fun pastDeadlinesFireOnTheNextLoop() {
        timers.schedule("late", 0)
        looper.idle()
        assertEquals(listOf("late"), fired.map { it.first })
    }

    @Test
    fun schedulingTheSameIdReplacesThePreviousTimer() {
        timers.schedule("flush", inMs(100))
        timers.schedule("flush", inMs(300))

        looper.idleFor(Duration.ofMillis(200))
        assertEquals(emptyList<Pair<String, Long>>(), fired)
        looper.idleFor(Duration.ofMillis(100))
        assertEquals(listOf("flush"), fired.map { it.first })
        looper.idleFor(Duration.ofSeconds(1))
        assertEquals("fires once", 1, fired.size)
    }

    @Test
    fun cancelStopsOnlyThatTimer() {
        timers.schedule("a", inMs(100))
        timers.schedule("b", inMs(100))
        timers.cancel("a")
        timers.cancel("unknown")

        looper.idleFor(Duration.ofMillis(100))
        assertEquals(listOf("b"), fired.map { it.first })
    }

    @Test
    fun timersFireInDeadlineOrder() {
        timers.schedule("late", inMs(30))
        timers.schedule("early", inMs(10))
        timers.schedule("middle", inMs(20))

        looper.idleFor(Duration.ofMillis(30))
        assertEquals(listOf("early", "middle", "late"), fired.map { it.first })
    }

    @Test
    fun cancelAllClearsEverything() {
        timers.schedule("a", inMs(10))
        timers.schedule("b", inMs(20))
        timers.cancelAll()

        looper.idleFor(Duration.ofSeconds(1))
        assertEquals(emptyList<Pair<String, Long>>(), fired)
        assertEquals(0, timers.scheduledCount)
    }
}
