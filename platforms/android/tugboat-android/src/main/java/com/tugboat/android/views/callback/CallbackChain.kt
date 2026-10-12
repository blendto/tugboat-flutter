package com.tugboat.android.views.callback

import android.app.Activity
import android.app.Dialog
import android.view.Window
import java.lang.reflect.Modifier
import java.lang.reflect.Proxy

/**
 * Finds Tugboat's wrapper in a window-callback chain that other SDKs may
 * have wrapped. Tugboat's own wrapper exposes its delegate; a foreign
 * wrapper is followed through a public `getWrapped()` / `getDelegate()`
 * accessor (AppCompat's `WindowCallbackWrapper`, Sentry's adapter), else
 * through the instance fields its own (non-platform)
 * classes declare that hold a `Window.Callback`, and through the invocation
 * handler of a `java.lang.reflect.Proxy`. Platform and JDK classes are never
 * inspected, so the walk reads no private Android or AndroidX state, and it
 * stops at [MAX_DEPTH] links. Any failure reads as "not found", which only
 * costs one extra (deduplicated) wrapper.
 */
internal object CallbackChain {
    const val MAX_DEPTH = 16
    private val ACCESSORS = listOf("getWrapped", "getDelegate")

    fun containsTugboat(top: Window.Callback?): Boolean =
        try {
            find(top, MAX_DEPTH)
        } catch (_: Throwable) {
            false
        }

    /** Tugboat wrappers reachable from [top]; for tests and diagnostics. */
    fun countTugboat(top: Window.Callback?): Int =
        try {
            generateSequence(top) { next(it) }.take(MAX_DEPTH * 4).count { it is TugboatWindowCallback }
        } catch (_: Throwable) {
            0
        }

    private fun find(callback: Window.Callback?, depth: Int): Boolean {
        if (callback == null || depth < 0) return false
        if (callback is TugboatWindowCallback) return true
        return find(next(callback), depth - 1)
    }

    /** The callback [callback] forwards to, or null when none is visible. */
    private fun next(callback: Window.Callback): Window.Callback? {
        if (callback is TugboatWindowCallback) return callback.delegate
        // The activity or dialog is where the chain ends.
        if (callback is Activity || callback is Dialog) return null
        if (Proxy.isProxyClass(callback.javaClass)) return wrappedCallbackOf(Proxy.getInvocationHandler(callback))
        return accessorOf(callback) ?: wrappedCallbackOf(callback)
    }

    private fun accessorOf(callback: Window.Callback): Window.Callback? {
        for (name in ACCESSORS) {
            val method = callback.javaClass.methods.firstOrNull {
                it.name == name && it.parameterTypes.isEmpty() && Window.Callback::class.java.isAssignableFrom(it.returnType)
            } ?: continue
            val value = method.invoke(callback)
            if (value is Window.Callback && value !== callback) return value
        }
        return null
    }

    private fun wrappedCallbackOf(holder: Any): Window.Callback? {
        var type: Class<*>? = holder.javaClass
        while (type != null && !isPlatform(type.name)) {
            for (field in type.declaredFields) {
                if (Modifier.isStatic(field.modifiers) || field.type.isPrimitive) continue
                if (!Window.Callback::class.java.isAssignableFrom(field.type) && field.type != Any::class.java) continue
                field.isAccessible = true
                val value = field.get(holder)
                if (value is Window.Callback && value !== holder) return value
            }
            type = type.superclass
        }
        return null
    }

    private fun isPlatform(name: String) =
        name.startsWith("android.") || name.startsWith("androidx.") || name.startsWith("java.") ||
            name.startsWith("javax.") || name.startsWith("kotlin.") || name.startsWith("com.android.")
}
