package com.tugboat.android.sdk

import com.tugboat.android.AppInfo
import java.util.Locale
import org.json.JSONObject

/**
 * The engine's `engine.configure.host` group and the session locale: every
 * field the collector requires on `session_start` (native SDK note section
 * 7). The collector answers 400 to a `session_start` without them and the
 * session is lost, so [missingFields] must be empty before a session starts.
 */
internal class HostMetadata(private val app: AppInfo, private val device: DeviceSnapshot) {
    /** Required fields that are blank or out of range, by wire path; empty when complete. */
    fun missingFields(): List<String> = buildList {
        requireText("app.name", app.name)
        requireText("app.version", app.version)
        requireText("app.buildNumber", app.buildNumber)
        requireText("app.appId", app.appId)
        requireText("app.installationId", app.installationId)
        requireText("device.id", device.id)
        requirePositive("device.screenSize.width", device.screenWidthDp)
        requirePositive("device.screenSize.height", device.screenHeightDp)
        requirePositive("device.screenDensity", device.density)
        requirePositive("device.screenDpi", device.densityDpi.toDouble())
        requireText("locale.language", device.locale.language)
        requireText("locale.tag", device.locale.toLanguageTag())
    }

    /** `engine.configure.host`. */
    fun hostJson(): JSONObject =
        JSONObject()
            .put("app", appJson())
            .put("device", deviceJson())
            .put("ip", JSONObject().put("ip", PLACEHOLDER_IP))
            .put("locale", configuredLocaleJson())

    /** `session.start.locale` (`TugboatLocaleInfo`): language and tag required. */
    fun sessionLocaleJson(): JSONObject = sessionLocaleJson(device.locale)

    private fun appJson(): JSONObject =
        JSONObject()
            .put("name", app.name)
            .put("version", app.version)
            .put("buildNumber", app.buildNumber)
            .put("installationId", app.installationId)
            .put("appId", app.appId)

    private fun deviceJson(): JSONObject {
        val json = JSONObject().put("id", device.id).put("platform", PLATFORM)
        device.manufacturer?.let { json.put("manufacturer", it) }
        device.model?.let { json.put("model", it) }
        device.osVersion?.let { json.put("osVersion", it) }
        return json
            .put("screenSize", JSONObject().put("width", device.screenWidthDp).put("height", device.screenHeightDp))
            .put("screenDensity", device.density)
            .put("screenDpi", device.densityDpi)
            .put("screenPixelDensity", device.density)
    }

    /** The configured locale (`TugboatCollectorLocaleInfo`): language, country, timezone. */
    private fun configuredLocaleJson(): JSONObject {
        val json = JSONObject().put("language", device.locale.language)
        device.locale.country.takeIf { it.isNotEmpty() }?.let { json.put("country", it) }
        return json.put("timezone", device.timezone)
    }

    private fun MutableList<String>.requireText(path: String, value: String?) {
        if (value.isNullOrBlank()) add(path)
    }

    private fun MutableList<String>.requirePositive(path: String, value: Double) {
        if (!(value > 0) || !value.isFinite()) add(path)
    }

    companion object {
        const val PLATFORM = "android"

        /**
         * `ipInfo.ip` is required but the device cannot know its public
         * address; Flutter's Android host sends the emulator's host loopback
         * as a placeholder, and so does this one (the collector may enrich
         * from the request).
         */
        const val PLACEHOLDER_IP = "10.0.2.2"

        /** `session.start.locale` / `locale.set.locale` for [locale]. */
        fun sessionLocaleJson(locale: Locale): JSONObject {
            val json = JSONObject().put("language", locale.language)
            locale.country.takeIf { it.isNotEmpty() }?.let { json.put("country", it) }
            locale.script.takeIf { it.isNotEmpty() }?.let { json.put("script", it) }
            return json.put("tag", locale.toLanguageTag())
        }
    }
}
