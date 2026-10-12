package com.tugboat.android.sdk

import android.content.Context
import android.os.Build
import java.util.Locale
import java.util.TimeZone

/**
 * The device values `session_start` carries, read once at start. Sizes are
 * logical pixels (dp), as in Flutter's `TugboatCollectorHost.fromPlatform`.
 */
internal data class DeviceSnapshot(
    /** `Build.ID`, the value Flutter's `device_info_plus` reports as `id`. */
    val id: String,
    val manufacturer: String?,
    val model: String?,
    val osVersion: String?,
    val screenWidthDp: Double,
    val screenHeightDp: Double,
    val density: Double,
    val densityDpi: Int,
    val locale: Locale,
    val timezone: String,
) {
    companion object {
        fun read(context: Context): DeviceSnapshot {
            val metrics = context.resources.displayMetrics
            val density = metrics.density.toDouble()
            val dp = density.takeIf { it > 0 } ?: 1.0
            return DeviceSnapshot(
                id = Build.ID.orEmpty(),
                manufacturer = Build.MANUFACTURER,
                model = Build.MODEL,
                osVersion = Build.VERSION.RELEASE,
                screenWidthDp = metrics.widthPixels / dp,
                screenHeightDp = metrics.heightPixels / dp,
                density = density,
                densityDpi = metrics.densityDpi,
                locale = primaryLocale(context),
                timezone = TimeZone.getDefault().id,
            )
        }

        private fun primaryLocale(context: Context): Locale {
            val locales = context.resources.configuration.locales
            return if (locales.isEmpty) Locale.getDefault() else locales[0]
        }
    }
}
