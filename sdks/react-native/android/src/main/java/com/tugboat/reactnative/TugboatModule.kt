package com.tugboat.reactnative

import android.app.Application
import android.content.pm.PackageManager
import android.util.Log
import com.facebook.react.bridge.ReactApplicationContext
import com.facebook.react.bridge.ReadableMap
import com.facebook.react.module.annotations.ReactModule
import com.tugboat.android.AppInfo
import com.tugboat.android.CollectorConfig
import com.tugboat.android.Tugboat
import com.tugboat.android.TugboatConfig

/** Each method is one call to the same-named `Tugboat` function. Nothing throws into the app. */
@ReactModule(name = TugboatModule.NAME)
class TugboatModule(reactContext: ReactApplicationContext) : NativeTugboatSpec(reactContext) {
    override fun getName(): String = NAME

    override fun start(config: ReadableMap) = guarded("start") {
        val application = reactApplicationContext.applicationContext as Application
        val collector = config.getMap("collector") ?: error("collector is missing")
        val app = config.getMap("app") ?: error("app is missing")
        val info = packageInfo(application)
        val appInfo = AppInfo(
            name = app.string("name") ?: application.applicationInfo.loadLabel(application.packageManager).toString(),
            version = app.string("version") ?: info?.versionName.orEmpty(),
            buildNumber = app.string("buildNumber") ?: info?.let { longVersionCode(it).toString() }.orEmpty(),
            appId = app.string("appId") ?: application.packageName,
            installationId = app.string("installationId").orEmpty(),
        )
        Tugboat.start(
            application,
            TugboatConfig(
                collector = CollectorConfig(
                    baseUrl = collector.string("baseUrl").orEmpty(),
                    apiKey = collector.string("apiKey").orEmpty(),
                ),
                app = appInfo,
                enabled = config.bool("enabled", false),
                // Only allTextAndMedia exists; any other string is that level too.
                captureFocusChanges = config.bool("captureFocusChanges", false),
                captureSystemInput = config.bool("captureSystemInput", false),
                captureDiagnostics = config.bool("captureDiagnostics", false),
                durableOutbox = config.bool("durableOutbox", false),
            ),
        )
        if (config.bool("captureNetwork", true)) {
            val hosts = config.getArray("networkAllowHosts")?.toArrayList()?.mapNotNull { it as? String }.orEmpty()
            TugboatNetwork.install(hosts.toSet())
        }
    }

    override fun activate(activationRequestId: String) = guarded("activate") { Tugboat.activate(activationRequestId) }

    override fun deactivate() = guarded("deactivate") { Tugboat.deactivate() }

    override fun stop() = guarded("stop") { Tugboat.stop() }

    override fun setUserId(id: String?) = guarded("setUserId") { Tugboat.setUserId(id) }

    override fun setTraits(traits: ReadableMap) = guarded("setTraits") { Tugboat.setTraits(traits.toHashMap()) }

    private fun guarded(what: String, block: () -> Unit) {
        try {
            block()
        } catch (t: Throwable) {
            Log.w(TAG, "$what failed", t)
        }
    }

    @Suppress("DEPRECATION")
    private fun packageInfo(application: Application) = try {
        application.packageManager.getPackageInfo(application.packageName, 0)
    } catch (_: PackageManager.NameNotFoundException) {
        null
    }

    @Suppress("DEPRECATION")
    private fun longVersionCode(info: android.content.pm.PackageInfo): Long =
        if (android.os.Build.VERSION.SDK_INT >= 28) info.longVersionCode else info.versionCode.toLong()

    private fun ReadableMap.string(key: String): String? =
        if (hasKey(key) && !isNull(key)) getString(key)?.takeIf { it.isNotBlank() } else null

    private fun ReadableMap.bool(key: String, default: Boolean): Boolean =
        if (hasKey(key) && !isNull(key)) getBoolean(key) else default

    companion object {
        const val NAME = "Tugboat"
        private const val TAG = "TugboatRN"
    }
}
