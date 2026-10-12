package com.tugboat.android.views.input

import android.view.View
import android.view.ViewTreeObserver
import com.tugboat.android.views.AdapterGuard
import com.tugboat.android.views.facts.FactClock
import com.tugboat.android.views.facts.FactTypes
import com.tugboat.android.views.facts.ViewsFact
import com.tugboat.android.views.identity.ViewRules
import org.json.JSONObject

/**
 * `focus {kind}` facts from a window's `OnGlobalFocusChangeListener`:
 * `text_input` when an editable `TextView` (`EditText` and subclasses) takes
 * focus, `none` when focus leaves the window's views, `other` otherwise.
 * Consecutive equal kinds are sent once. The engine records only
 * transitions that involve a text input.
 */
internal class FocusFactProducer(
    private val clock: FactClock,
    private val emit: (ViewsFact) -> Unit,
) : ViewTreeObserver.OnGlobalFocusChangeListener {
    private var lastKind: String? = null

    override fun onGlobalFocusChanged(oldFocus: View?, newFocus: View?) =
        AdapterGuard.run("focus change") {
            val kind = kindOf(newFocus)
            if (kind == lastKind) return@run
            lastKind = kind
            emit(ViewsFact(FactTypes.FOCUS, JSONObject().put("kind", kind), clock.now()))
        }

    private fun kindOf(view: View?): String =
        when {
            view == null -> "none"
            ViewRules.isEditable(view) -> "text_input"
            else -> "other"
        }
}
