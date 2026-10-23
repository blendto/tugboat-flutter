package com.tugboat.android.views

import com.tugboat.android.views.identity.Confidence
import com.tugboat.android.views.navigation.NavigationProcessState
import com.tugboat.android.views.navigation.OverlayKind
import com.tugboat.android.views.navigation.RouteEntry
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Before
import org.junit.Test

/** The order of `session_start` seeds: covered navigators first, visible chain last. */
class SessionStartOrderTest {
    @Before
    fun reset() = NavigationProcessState.resetForTests()

    @After
    fun clear() = NavigationProcessState.resetForTests()

    @Test
    fun seedsGoParentFirstWithTheVisibleChainLastWhateverTheIdDigits() {
        val task = NavigationProcessState.activityStack(7, "activities:7")
        val a = entry("activity-8")
        val b = entry("activity-11")
        task.push(a)
        task.push(b)
        NavigationProcessState.fragmentStack("activity-8/fragments", "activities:7", "activity-8")
            .push(entry("fragment-9"))
        val hostFragment = entry("fragment-10")
        NavigationProcessState.fragmentStack("activity-11/fragments", "activities:7", "activity-11")
            .push(hostFragment)
        NavigationProcessState.fragmentStack("fragment-10/fragments", "activity-11/fragments", "fragment-10")
            .push(entry("fragment-12"))
        NavigationProcessState.controllerStack("activity-11/nav", "activities:7", "activity-11")
            .push(entry("dest-13"))

        val order = NavigationProcessState.sessionStartSnapshots().map { it.navigatorId }

        assertEquals(
            listOf(
                "activity-8/fragments",
                "activities:7",
                "activity-11/fragments",
                "fragment-10/fragments",
                "activity-11/nav",
            ),
            order,
        )
    }

    @Test
    fun lowerActivityFragmentsDoNotFollowTheTopActivityWhenItHostsNothing() {
        val task = NavigationProcessState.activityStack(3, "activities:3")
        val main = entry("activity-main")
        val settings = entry("activity-settings")
        task.push(main)
        task.push(settings)
        NavigationProcessState.fragmentStack("activity-main/fragments", "activities:3", "activity-main")
            .push(entry("fragment-home"))

        val order = NavigationProcessState.sessionStartSnapshots().map { it.navigatorId }

        assertEquals(listOf("activity-main/fragments", "activities:3"), order)
    }

    @Test
    fun navigatorsWhoseHostIsGoneComeFirst() {
        NavigationProcessState.activityStack(1, "activities:1").push(entry("activity-2"))
        NavigationProcessState.fragmentStack("activity-99/fragments", "activities:1", "activity-99")
            .push(entry("fragment-100"))
        NavigationProcessState.fragmentStack("activity-2/fragments", "activities:1", "activity-2")
            .push(entry("fragment-3"))

        val order = NavigationProcessState.sessionStartSnapshots().map { it.navigatorId }

        assertEquals(listOf("activity-99/fragments", "activities:1", "activity-2/fragments"), order)
    }

    @Test
    fun foregroundTaskIsSeededLastAmongSeveralTasks() {
        NavigationProcessState.activityStack(1, "activities:1").push(entry("activity-a"))
        NavigationProcessState.activityStack(9, "activities:9").push(entry("activity-b"))
        NavigationProcessState.noteResumed(1)

        val order = NavigationProcessState.sessionStartSnapshots().map { it.navigatorId }

        assertEquals(listOf("activities:9", "activities:1"), order)
    }

    private fun entry(id: String) = RouteEntry(id, id, Confidence.High, "Test", OverlayKind.Page)
}
