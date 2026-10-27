package com.tugboat.android.sdk

import android.app.Activity
import android.content.Intent
import android.os.Bundle
import com.tugboat.android.TugboatLifecycleState
import com.tugboat.android.wireName
import org.json.JSONObject

/** Device Farm intent extras; spellings match the Flutter plugin. */
internal object LaunchExtraKeys {
    const val EMIT_SCENE_INVENTORY = "tugboat_emit_scene_inventory"
    const val ACCEPT_ACTION_CONTEXT = "tugboat_accept_action_context"
    const val AUTOMATION_RUN_ID = "tugboat_automation_run_id"
}

/**
 * Parsed launch inputs from the first resumed activity whose intent carries
 * capture extras. Collector URL extra is ignored (v1 does not apply overrides;
 * see README).
 */
internal data class LaunchOptions(
    val emitSceneInventory: Boolean,
    val acceptActionContext: Boolean,
    val automationRunId: String?,
) {
    val captureRequested: Boolean
        get() = emitSceneInventory || acceptActionContext

    fun toLaunchJson(sessionWallUs: Long): String {
        val parts = buildList {
            add("\"captureRequested\":true")
            add("\"emitSceneInventory\":$emitSceneInventory")
            add("\"acceptActionContext\":$acceptActionContext")
            val runId = automationRunId
            if (runId != null) {
                add("\"automationRunId\":${JSONObject.quote(runId)}")
            }
            add("\"captureSessionId\":\"session-$sessionWallUs\"")
        }
        return "{${parts.joinToString(",")}}"
    }

    companion object {
        /**
         * `lifecycle` is the state's Flutter name; `activationRequestId` when
         * set; `captureSessionId` unless dormant.
         */
        fun healthJson(lifecycle: LifecycleSnapshot, sessionWallUs: Long): String {
            val json = JSONObject().put("lifecycle", lifecycle.state.wireName)
            lifecycle.activationRequestId?.let { json.put("activationRequestId", it) }
            if (lifecycle.state != TugboatLifecycleState.DORMANT) {
                json.put("captureSessionId", "session-$sessionWallUs")
            }
            return json.toString()
        }

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
    fun parseBool(value: String?): Boolean {
        val normalized = value?.trim()?.lowercase()
        return normalized == "1" || normalized == "true" || normalized == "yes"
    }
}
