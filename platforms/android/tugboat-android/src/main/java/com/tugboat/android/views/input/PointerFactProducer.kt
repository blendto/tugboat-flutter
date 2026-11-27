package com.tugboat.android.views.input

import android.view.MotionEvent
import com.tugboat.android.host.HostTime
import com.tugboat.android.views.AdapterGuard
import com.tugboat.android.views.facts.FactClock
import com.tugboat.android.views.facts.FactTypes
import com.tugboat.android.views.facts.ViewsFact
import com.tugboat.android.views.identity.TapEvidence
import org.json.JSONObject

/**
 * Turns one window's `MotionEvent`s into `input.pointer` facts
 * (stateful-engine.md 9.1).
 *
 * - One fact per pointer per event: `down` for `ACTION_DOWN` /
 *   `ACTION_POINTER_DOWN`, `move` for every pointer of `ACTION_MOVE`, `up`
 *   for `ACTION_UP` / `ACTION_POINTER_UP`, `cancel` for every pointer of
 *   `ACTION_CANCEL`. Historical samples are not sent.
 * - `x`, `y` are logical pixels (dp) in the adapter's surface space: the
 *   activity window's decor. A dialog window's events are moved there by
 *   [surfaceOffset] (read once per event); the activity's own is zero.
 * - `at.monoUs` is the event time ([FactClock.at]).
 * - On `up`, when the contact never travelled [GestureConfig.touchSlop] or
 *   more (the engine's swipe test is `distance >= touchSlop`), [resolveTap]
 *   resolves the target at the **down** position, in physical pixels of
 *   the window that received it (without the offset), against the current
 *   tree, and the fact carries `tap`.
 *
 * Main thread only.
 */
internal class PointerFactProducer(
    private val clock: FactClock,
    private val gesture: GestureConfig,
    private val density: () -> Float,
    private val resolveTap: (downXPx: Float, downYPx: Float) -> TapEvidence,
    private val emit: (ViewsFact) -> Unit,
    /** This window's origin in the surface space; zero for the activity's own window. */
    private val surfaceOffset: () -> SurfaceOffset = { SurfaceOffset.ZERO },
) {
    private val contacts = PointerContacts()

    fun onTouch(event: MotionEvent) {
        val at = clock.at(event)
        val offset = surfaceOffset()
        when (event.actionMasked) {
            MotionEvent.ACTION_DOWN -> {
                cancelStale(at)
                begin(event, 0, offset, at)
            }
            MotionEvent.ACTION_POINTER_DOWN -> begin(event, event.actionIndex, offset, at)
            MotionEvent.ACTION_MOVE -> for (i in 0 until event.pointerCount) move(event, i, offset, at)
            MotionEvent.ACTION_POINTER_UP, MotionEvent.ACTION_UP -> up(event, event.actionIndex, offset, at)
            MotionEvent.ACTION_CANCEL -> for (i in 0 until event.pointerCount) cancel(event, i, offset, at)
        }
    }

    private fun begin(event: MotionEvent, index: Int, offset: SurfaceOffset, at: HostTime) {
        val xPx = event.getX(index)
        val yPx = event.getY(index)
        val contact = contacts.begin(event.getPointerId(index), dp(xPx + offset.xPx), dp(yPx + offset.yPx), xPx, yPx)
        emit(fact(contact.contactId, PHASE_DOWN, contact.downX, contact.downY, device(event, index), at))
    }

    private fun move(event: MotionEvent, index: Int, offset: SurfaceOffset, at: HostTime) {
        val contact = contacts[event.getPointerId(index)] ?: return
        val x = dp(event.getX(index) + offset.xPx)
        val y = dp(event.getY(index) + offset.yPx)
        contact.moveTo(x, y)
        emit(fact(contact.contactId, PHASE_MOVE, x, y, device(event, index), at))
    }

    private fun up(event: MotionEvent, index: Int, offset: SurfaceOffset, at: HostTime) {
        val contact = contacts.end(event.getPointerId(index)) ?: return
        val x = dp(event.getX(index) + offset.xPx)
        val y = dp(event.getY(index) + offset.yPx)
        contact.moveTo(x, y)
        val input = input(contact.contactId, PHASE_UP, x, y, device(event, index))
        if (contact.maxTravel < gesture.touchSlop) {
            input.put("tap", tapAt(contact).toJson())
        }
        emit(ViewsFact(FactTypes.POINTER, input, at))
    }

    private fun cancel(event: MotionEvent, index: Int, offset: SurfaceOffset, at: HostTime) {
        val contact = contacts.end(event.getPointerId(index)) ?: return
        val x = dp(event.getX(index) + offset.xPx)
        val y = dp(event.getY(index) + offset.yPx)
        emit(fact(contact.contactId, PHASE_CANCEL, x, y, device(event, index), at))
    }

    private fun tapAt(contact: Contact): TapEvidence {
        val failed = TapEvidence.failed(TapEvidence.RESOLUTION_ERROR)
        return AdapterGuard.run("tap resolution", failed) {
            resolveTap(contact.windowDownXPx, contact.windowDownYPx)
        }
    }

    /** A down while contacts are open means their up was never delivered: cancel them. */
    private fun cancelStale(at: HostTime) {
        for ((_, contact) in contacts.endAll()) {
            emit(fact(contact.contactId, PHASE_CANCEL, contact.lastX, contact.lastY, DEVICE_TOUCH, at))
        }
    }

    private fun fact(id: Long, phase: String, x: Double, y: Double, device: String, at: HostTime) =
        ViewsFact(FactTypes.POINTER, input(id, phase, x, y, device), at)

    private fun input(id: Long, phase: String, x: Double, y: Double, device: String): JSONObject =
        JSONObject().put("pointerId", id).put("phase", phase).put("x", x).put("y", y).put("device", device)

    private fun dp(px: Float): Double = px.toDouble() / scale()

    private fun scale(): Double = density().toDouble().takeIf { it > 0 } ?: 1.0

    private fun device(event: MotionEvent, index: Int): String =
        when (event.getToolType(index)) {
            MotionEvent.TOOL_TYPE_STYLUS, MotionEvent.TOOL_TYPE_ERASER -> "stylus"
            MotionEvent.TOOL_TYPE_MOUSE -> "mouse"
            else -> DEVICE_TOUCH
        }

    private companion object {
        const val PHASE_DOWN = "down"
        const val PHASE_MOVE = "move"
        const val PHASE_UP = "up"
        const val PHASE_CANCEL = "cancel"
        const val DEVICE_TOUCH = "touch"
    }
}
