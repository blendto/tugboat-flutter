package com.tugboat.android.views.facts

import com.tugboat.android.host.EngineMessage
import com.tugboat.android.host.HostTime
import org.json.JSONObject

/**
 * One fact the Views adapter observed: an engine message `type`, its `input`
 * object, and the time the fact happened (not when it is posted).
 */
internal class ViewsFact(val type: String, val input: JSONObject, val at: HostTime) {
    fun toMessage(): EngineMessage = EngineMessage(type, input.toString(), at)

    override fun toString(): String = "$type@${at.monoUs} $input"
}

/** The engine message types the adapter produces (stateful-engine.md 8.1 and 9.1). */
internal object FactTypes {
    const val POINTER = "input.pointer"
    const val SCROLL = "scroll"
    const val FOCUS = "focus"
    const val SYSTEM_INPUT = "systemInput"

    /** Phase 3d: the engine rejects this type until navigation lands. */
    const val NAVIGATION = "navigation"
}
