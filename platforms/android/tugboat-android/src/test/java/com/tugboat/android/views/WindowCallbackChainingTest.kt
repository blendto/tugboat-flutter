package com.tugboat.android.views

import android.app.Activity
import android.os.SystemClock
import android.view.KeyEvent
import android.view.MotionEvent
import android.view.Window
import android.view.accessibility.AccessibilityEvent
import com.tugboat.android.views.callback.ObservingWindowCallback
import com.tugboat.android.views.callback.WindowCallbackInstaller
import com.tugboat.android.views.callback.WindowEventObserver
import org.junit.Assert.assertEquals
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import java.lang.reflect.Method
import java.lang.reflect.Proxy

/**
 * Native SDK note section 5: with foreign wrappers installed before and
 * after Tugboat's, every `Window.Callback` method reaches the original
 * callback exactly once, and Tugboat observes each event once.
 */
@RunWith(RobolectricTestRunner::class)
class WindowCallbackChainingTest {
    private val window: Window = Robolectric.buildActivity(Activity::class.java).setup().get().window
    private val original = RecordingCallback()
    private val observer = CountingObserver()

    @Test
    fun everyMethodReachesTheOriginalOnceWithForeignWrappersBeforeAndAfter() {
        window.callback = original.proxy
        window.callback = forwarding(window.callback)
        WindowCallbackInstaller.ensureInstalled(window, observer)
        window.callback = forwarding(window.callback)
        // Resume: the foreign wrapper is on top, so Tugboat wraps again.
        WindowCallbackInstaller.ensureInstalled(window, observer)
        assertTrue(window.callback is ObservingWindowCallback)

        invokeEveryMethod(window.callback)

        assertEquals(callbackMethods().map { it.signature() }.toSet(), original.calls.keys)
        original.calls.forEach { (method, count) -> assertEquals(method, 1, count) }
        assertEquals("touch observed once", 1, observer.touches)
        assertEquals("key observed once", 1, observer.keys)
    }

    @Test
    fun neverWrapsItsOwnWrapperTwice() {
        window.callback = original.proxy
        WindowCallbackInstaller.ensureInstalled(window, observer)
        val ours = window.callback
        WindowCallbackInstaller.ensureInstalled(window, observer)
        assertSame(ours, window.callback)
        assertSame(original.proxy, (ours as ObservingWindowCallback).delegate)
    }

    @Test
    fun rewrapsWhenAnotherSdkReplacedTheCallbackWithoutChaining() {
        window.callback = original.proxy
        WindowCallbackInstaller.ensureInstalled(window, observer)
        val replacement = RecordingCallback()
        window.callback = replacement.proxy

        WindowCallbackInstaller.ensureInstalled(window, observer)
        window.callback.dispatchTouchEvent(touch())

        assertEquals(1, observer.touches)
        assertEquals(1, replacement.calls[DISPATCH_TOUCH])
    }

    @Test
    fun observerFailuresNeverReachTheApp() {
        window.callback = original.proxy
        WindowCallbackInstaller.ensureInstalled(window, ThrowingObserver())

        window.callback.dispatchTouchEvent(touch())

        assertEquals(1, original.calls[DISPATCH_TOUCH])
    }

    @Test
    fun uninstallRestoresTheDelegateOnlyWhenOnTop() {
        window.callback = original.proxy
        WindowCallbackInstaller.ensureInstalled(window, observer)
        WindowCallbackInstaller.uninstall(window)
        assertSame(original.proxy, window.callback)
    }

    private fun invokeEveryMethod(callback: Window.Callback) {
        for (method in callbackMethods()) {
            val args = method.parameterTypes.map(::argumentFor).toTypedArray()
            method.invoke(callback, *args)
        }
    }

    private fun argumentFor(type: Class<*>): Any? =
        when (type) {
            Int::class.javaPrimitiveType -> 0
            Boolean::class.javaPrimitiveType -> false
            MotionEvent::class.java -> touch()
            KeyEvent::class.java -> KeyEvent(KeyEvent.ACTION_DOWN, KeyEvent.KEYCODE_A)
            AccessibilityEvent::class.java -> AccessibilityEvent.obtain()
            // Menu, MenuItem, ActionMode.Callback, List: a do-nothing instance.
            else -> if (type.isInterface) inert(type) else null
        }

    private fun inert(type: Class<*>): Any =
        Proxy.newProxyInstance(type.classLoader, arrayOf(type)) { _, method, _ -> defaultReturn(method) }

    private fun touch(): MotionEvent {
        val now = SystemClock.uptimeMillis()
        return MotionEvent.obtain(now, now, MotionEvent.ACTION_DOWN, 1f, 1f, 0)
    }

    private class RecordingCallback {
        val calls = LinkedHashMap<String, Int>()
        val proxy: Window.Callback =
            Proxy.newProxyInstance(javaClass.classLoader, arrayOf(Window.Callback::class.java)) { _, method, _ ->
                calls.merge(method.signature(), 1, Int::plus)
                defaultReturn(method)
            } as Window.Callback
    }

    private class CountingObserver : WindowEventObserver {
        var touches = 0
        var keys = 0

        override fun onTouch(event: MotionEvent) {
            touches++
        }

        override fun onKey(event: KeyEvent) {
            keys++
        }
    }

    private class ThrowingObserver : WindowEventObserver {
        override fun onTouch(event: MotionEvent) = throw IllegalStateException("observer bug")

        override fun onKey(event: KeyEvent) = throw IllegalStateException("observer bug")
    }

    private companion object {
        val DISPATCH_TOUCH = "dispatchTouchEvent(MotionEvent)"

        fun callbackMethods(): List<Method> = Window.Callback::class.java.methods.sortedBy { it.signature() }

        fun Method.signature(): String = "$name(${parameterTypes.joinToString(",") { it.simpleName }})"

        /** A foreign SDK's wrapper: forwards every method, including default ones, to [inner]. */
        fun forwarding(inner: Window.Callback): Window.Callback =
            Proxy.newProxyInstance(Window.Callback::class.java.classLoader, arrayOf(Window.Callback::class.java)) { _, method, args ->
                method.invoke(inner, *(args ?: emptyArray()))
            } as Window.Callback

        fun defaultReturn(method: Method): Any? =
            when (method.returnType) {
                Boolean::class.javaPrimitiveType -> false
                else -> null
            }
    }
}
