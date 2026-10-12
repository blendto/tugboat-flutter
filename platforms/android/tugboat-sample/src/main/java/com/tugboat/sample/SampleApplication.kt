package com.tugboat.sample

import android.app.Application
import com.tugboat.android.AppInfo
import com.tugboat.android.CollectorConfig
import com.tugboat.android.Tugboat
import com.tugboat.android.TugboatConfig
import com.tugboat.android.compose.ComposeMasking
import com.tugboat.android.compose.TugboatCompose
import java.util.UUID

/** Starts Tugboat before any activity exists, as the SDK requires. */
class SampleApplication : Application() {
    override fun onCreate() {
        super.onCreate()
        Tugboat.start(
            this,
            TugboatConfig(
                collector = CollectorConfig(BuildConfig.COLLECTOR_URL, BuildConfig.COLLECTOR_KEY),
                app = AppInfo(
                    name = getString(R.string.app_name),
                    version = BuildConfig.VERSION_NAME,
                    buildNumber = BuildConfig.VERSION_CODE.toString(),
                    appId = BuildConfig.APPLICATION_ID,
                    installationId = installationId(),
                ),
                captureFocusChanges = true,
                captureSystemInput = true,
            ),
        )
        // Compose hosts are read by the Compose adapter, masked whole by default;
        // ComposeSemanticsActivity opts into semantics masking while resumed.
        TugboatCompose.install(composeMasking = ComposeMasking.WholeHost)
        Tugboat.setTraits(mapOf("sample" to true))
    }

    /** A UUID kept for the life of the install. */
    private fun installationId(): String {
        val preferences = getSharedPreferences("tugboat-sample", MODE_PRIVATE)
        preferences.getString(KEY_INSTALLATION_ID, null)?.let { return it }
        val id = UUID.randomUUID().toString()
        preferences.edit().putString(KEY_INSTALLATION_ID, id).apply()
        return id
    }

    private companion object {
        const val KEY_INSTALLATION_ID = "installationId"
    }
}
