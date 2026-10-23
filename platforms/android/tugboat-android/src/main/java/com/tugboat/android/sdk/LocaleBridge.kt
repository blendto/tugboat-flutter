package com.tugboat.android.sdk

import android.app.Application
import android.content.ComponentCallbacks
import android.content.res.Configuration
import com.tugboat.android.views.AdapterGuard

/**
 * Posts `locale.set` when the app's primary locale changes
 * (`ComponentCallbacks.onConfigurationChanged` on the [Application]).
 * Locale is evidence, not identity. Main thread only.
 */
internal class LocaleBridge(
    private val application: Application,
    private val post: (input: String) -> Unit,
) : ComponentCallbacks {
    private var observing = false
    private var lastTag: String? = null

    fun seedInitial(locale: java.util.Locale) {
        lastTag = locale.toLanguageTag()
    }

    fun start() = AdapterGuard.run("locale start") {
        if (observing) return@run
        observing = true
        application.registerComponentCallbacks(this)
    }

    fun stop() = AdapterGuard.run("locale stop") {
        if (!observing) return@run
        observing = false
        application.unregisterComponentCallbacks(this)
    }

    override fun onConfigurationChanged(newConfig: Configuration) =
        AdapterGuard.run("locale configuration") {
            if (!observing) return@run
            val locale = DeviceSnapshot.primaryLocale(newConfig)
            val tag = locale.toLanguageTag()
            if (tag == lastTag) return@run
            lastTag = tag
            post(SessionMessages.localeSet(HostMetadata.sessionLocaleJson(locale)))
        }

    override fun onLowMemory() = Unit
}
