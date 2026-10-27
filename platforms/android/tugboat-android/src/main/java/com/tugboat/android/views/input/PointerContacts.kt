package com.tugboat.android.views.input

import java.util.concurrent.atomic.AtomicLong
import kotlin.math.hypot

/**
 * One finger (or stylus, or mouse button) from its down to its up or cancel.
 * [downX], [downY] are dp in the adapter's surface space (what the facts
 * report); [windowDownXPx], [windowDownYPx] are the same point in physical
 * pixels of the window that received it (where its tap is hit-tested).
 */
internal class Contact(
    val contactId: Long,
    val downX: Double,
    val downY: Double,
    val windowDownXPx: Float,
    val windowDownYPx: Float,
) {
    /** Largest distance from the down point so far, in dp. */
    var maxTravel = 0.0
        private set
    var lastX = downX
        private set
    var lastY = downY
        private set

    fun moveTo(x: Double, y: Double) {
        lastX = x
        lastY = y
        val travel = hypot(x - downX, y - downY)
        if (travel > maxTravel) maxTravel = travel
    }
}

/**
 * Maps Android pointer ids to engine `pointerId`s. Android recycles pointer
 * ids (the first finger is always 0), but the engine requires a unique id
 * per contact: it cancels a released tap when an id is reused. Each down
 * gets the next id of one process-wide, monotonically increasing counter,
 * so windows tracked by separate instances never share an id.
 */
internal class PointerContacts {
    private val active = HashMap<Int, Contact>()

    fun begin(androidId: Int, x: Double, y: Double, windowXPx: Float, windowYPx: Float): Contact {
        val contact = Contact(nextContactId.getAndIncrement(), x, y, windowXPx, windowYPx)
        active[androidId] = contact
        return contact
    }

    operator fun get(androidId: Int): Contact? = active[androidId]

    fun end(androidId: Int): Contact? = active.remove(androidId)

    /** Removes and returns every active contact (cancel, or a down after a lost up). */
    fun endAll(): List<Pair<Int, Contact>> {
        val all = active.entries.map { it.key to it.value }
        active.clear()
        return all
    }

    private companion object {
        val nextContactId = AtomicLong(1)
    }
}
