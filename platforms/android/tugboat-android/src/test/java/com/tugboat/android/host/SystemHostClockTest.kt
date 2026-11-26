package com.tugboat.android.host

import android.os.Looper
import android.os.SystemClock
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import java.time.Duration

@RunWith(RobolectricTestRunner::class)
class SystemHostClockTest {
    // API 35+ reads SystemClock.uptimeNanos(), the same clock at nanosecond
    // resolution. Robolectric 4.14 does not shadow it, so only the
    // uptimeMillis path is checked here.
    @Test
    @Config(sdk = [34])
    fun monoUsIsUptimeMillisInMicrosBelowApi35() = assertUptimeTimebase()

    @Test
    fun wallUsIsEpochMicros() {
        val before = System.currentTimeMillis() * 1000
        val wall = SystemHostClock.now().wallUs
        assertTrue(wall >= before && wall <= System.currentTimeMillis() * 1000)
    }

    private fun assertUptimeTimebase() {
        shadowOf(Looper.getMainLooper()).idleFor(Duration.ofMillis(1234))
        assertEquals(SystemClock.uptimeMillis() * 1000, SystemHostClock.now().monoUs)
    }
}
