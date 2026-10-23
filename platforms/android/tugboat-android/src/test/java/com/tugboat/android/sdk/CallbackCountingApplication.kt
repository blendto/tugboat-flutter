package com.tugboat.android.sdk

import android.app.Application
import android.content.ComponentCallbacks

/** Counts [registerComponentCallbacks] / [unregisterComponentCallbacks] for JVM tests. */
class CallbackCountingApplication : Application() {
    private val registered = LinkedHashSet<ComponentCallbacks>()

    override fun registerComponentCallbacks(callback: ComponentCallbacks) {
        registered.add(callback)
        super.registerComponentCallbacks(callback)
    }

    override fun unregisterComponentCallbacks(callback: ComponentCallbacks) {
        registered.remove(callback)
        super.unregisterComponentCallbacks(callback)
    }

    fun componentCallbackCount(): Int = registered.size
}
