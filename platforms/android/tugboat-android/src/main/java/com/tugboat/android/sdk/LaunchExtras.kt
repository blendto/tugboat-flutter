package com.tugboat.android.sdk

import android.app.Activity
import android.content.Intent
import android.os.Bundle

/** Device Farm intent extras; spellings match the Flutter plugin. */
internal object LaunchExtraKeys {
    const val EMIT_SCENE_INVENTORY = "tugboat_emit_scene_inventory"
    const val ACCEPT_ACTION_CONTEXT = "tugboat_accept_action_context"
    const val COLLECTOR_BASE_URL = "tugboat_collector_base_url"
    const val AUTOMATION_RUN_ID = "tugboat_automation_run_id"
}

/**
 * Parsed launch inputs from the first resumed activity's intent. Collector
 * URL is read but never logged (v1 does not apply the override; see README).
 */
internal data class LaunchOptions(
    val emitSceneInventory: Boolean,
    val acceptActionContext: Boolean,
    val automationRunId: String?,
) {
    val captureRequested: Boolean
        get() = emitSceneInventory || acceptActionContext

    fun toLaunchJson(sessionWallUs: Long?): String {
        val parts = buildList {
            add("\"captureRequested\":true")
            add("\"emitSceneInventory\":$emitSceneInventory")
            add("\"acceptActionContext\":$acceptActionContext")
            val runId = automationRunId
            if (runId != null) {
                add("\"automationRunId\":${jsonString(runId)}")
            }
            if (sessionWallUs != null) {
                add("\"captureSessionId\":\"session-$sessionWallUs\"")
            }
        }
        return "{${parts.joinToString(",")}}"
    }

    companion object {
        fun healthJson(lifecycle: String, sessionWallUs: Long): String =
            "{\"lifecycle\":${jsonString(lifecycle)},\"captureSessionId\":\"session-$sessionWallUs\"}"

        fun fromActivity(activity: Activity): LaunchOptions? {
            val intent = activity.intent ?: return null
            val extras = intent.extras
            val emit = TugboatLaunchParsers.parseBool(rawExtra(extras, LaunchExtraKeys.EMIT_SCENE_INVENTORY))
            val accept = TugboatLaunchParsers.parseBool(rawExtra(extras, LaunchExtraKeys.ACCEPT_ACTION_CONTEXT))
            val options = LaunchOptions(
                emitSceneInventory = emit,
                acceptActionContext = accept,
                automationRunId = automationRunId(intent),
            )
            return if (options.captureRequested) options else null
        }

        private fun automationRunId(intent: Intent): String? {
            val raw = intent.getStringExtra(LaunchExtraKeys.AUTOMATION_RUN_ID)
                ?: rawExtra(intent.extras, LaunchExtraKeys.AUTOMATION_RUN_ID)
            val trimmed = raw?.trim()
            return if (trimmed.isNullOrEmpty()) null else trimmed
        }

        private fun rawExtra(extras: Bundle?, name: String): String? =
            extras?.get(name)?.toString()
    }
}

/** Normalization shared with Dart `TugboatLaunchParsers`. */
internal object TugboatLaunchParsers {
    fun parseBool(value: Any?): Boolean {
        if (value is Boolean) return value
        val normalized = value?.toString()?.trim()?.lowercase()
        return normalized == "1" || normalized == "true" || normalized == "yes"
    }
}

private fun jsonString(value: String): String =
    buildString(value.length + 2) {
        append('"')
        value.forEach { ch ->
            when (ch) {
                '\\' -> append("\\\\")
                '"' -> append("\\\"")
                '\n' -> append("\\n")
                '\r' -> append("\\r")
                '\t' -> append("\\t")
                else -> append(ch)
            }
        }
        append('"')
    }
