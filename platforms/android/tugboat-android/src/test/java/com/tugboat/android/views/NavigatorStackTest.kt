package com.tugboat.android.views

import com.tugboat.android.views.identity.Confidence
import com.tugboat.android.views.navigation.NavigationKind
import com.tugboat.android.views.navigation.NavigatorStack
import com.tugboat.android.views.navigation.OverlayKind
import com.tugboat.android.views.navigation.RouteEntry
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Test

class NavigatorStackTest {
    private val stack = NavigatorStack("nav", "parent")
    private val a = entry("a")
    private val b = entry("b")
    private val c = entry("c")

    @Test
    fun pushCoversTheTop() {
        val first = stack.push(a)
        assertEquals(NavigationKind.Push, first.kind)
        assertNull(first.departing)
        val second = stack.push(b)
        assertSame(b, second.route)
        assertSame(a, second.departing)
        assertEquals("parent", second.parentNavigatorId)
    }

    @Test
    fun replaceSwapsTheTop() {
        stack.push(a)
        val change = stack.replace(b)
        assertEquals(NavigationKind.Replace, change.kind)
        assertSame(a, change.departing)
        assertSame(b, stack.top)
        assertEquals(emptyList<RouteEntry>(), stack.above(b))
    }

    @Test
    fun popToRemovesEverythingAbove() {
        stack.push(a)
        stack.push(b)
        stack.push(c)
        val change = stack.popTo(a)!!
        assertEquals(NavigationKind.Pop, change.kind)
        assertSame(a, change.route)
        assertSame(c, change.departing)
        assertSame(a, stack.top)
        assertNull("already on top", stack.popTo(a))
    }

    @Test
    fun removingTheTopPopsAndRemovingBelowIsARemove() {
        stack.push(a)
        stack.push(b)
        stack.push(c)
        val below = stack.remove(b)!!
        assertEquals(NavigationKind.Remove, below.kind)
        assertSame(c, below.route)
        assertSame(b, below.departing)
        val top = stack.remove(c)!!
        assertEquals(NavigationKind.Pop, top.kind)
        assertSame(a, top.route)
        assertNull("nothing left to show", stack.remove(a))
    }

    private fun entry(name: String) = RouteEntry(name, name, Confidence.High, "Activity", OverlayKind.Page)
}
