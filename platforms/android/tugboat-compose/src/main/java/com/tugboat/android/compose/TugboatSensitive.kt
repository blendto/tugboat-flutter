package com.tugboat.android.compose

import android.view.View
import androidx.compose.ui.Modifier
import androidx.compose.ui.layout.LayoutCoordinates
import androidx.compose.ui.node.CompositionLocalConsumerModifierNode
import androidx.compose.ui.node.GlobalPositionAwareModifierNode
import androidx.compose.ui.node.ModifierNodeElement
import androidx.compose.ui.node.currentValueOf
import androidx.compose.ui.platform.InspectorInfo
import androidx.compose.ui.platform.LocalView
import java.util.WeakHashMap

/**
 * Marks this element and everything Compose lays out inside it as always
 * masked in screenshots, at every mask level, including under
 * [ComposeMasking.SemanticsBestEffort]:
 *
 * - the element's bounds at this point in the modifier chain (like
 *   `background`: before `padding` it covers the padding), unclipped;
 * - every semantics node laid out inside it, at its own unclipped bounds, so
 *   a child placed outside the element (`offset`) is covered too.
 *
 * Under the default [ComposeMasking.WholeHost] the host is already masked
 * whole. Drawing that has no semantics node of its own and lands outside the
 * element's bounds (an overflowing `drawBehind`) is not covered.
 *
 * It adds no semantics: tap targets, canonical paths, list items, scroll
 * targets, scene inventory, and fingerprints are the same with or without
 * it, and `clearAndSetSemantics` on the same element (in either order) does
 * not remove it. Remove the modifier to stop masking; it has no `false` form.
 */
fun Modifier.tugboatSensitive(): Modifier = this.then(TugboatSensitiveElement)

/** The element behind [tugboatSensitive]; `ComposeMasks` finds it in a node's modifier chain. */
internal object TugboatSensitiveElement : ModifierNodeElement<TugboatSensitiveNode>() {
    override fun create() = TugboatSensitiveNode()

    override fun update(node: TugboatSensitiveNode) = Unit

    override fun hashCode(): Int = javaClass.hashCode()

    override fun equals(other: Any?): Boolean = other === this

    override fun InspectorInfo.inspectableProperties() {
        name = "tugboatSensitive"
    }
}

/**
 * Registers with its Compose host while attached, and keeps the layout
 * coordinates it is placed with, so masks read its bounds at capture time.
 */
internal class TugboatSensitiveNode :
    Modifier.Node(),
    GlobalPositionAwareModifierNode,
    CompositionLocalConsumerModifierNode {
    private var host: View? = null

    /** Null until first placed. */
    var coordinates: LayoutCoordinates? = null
        private set

    override fun onAttach() {
        val view = runCatching { currentValueOf(LocalView) }.getOrNull() ?: return
        host = view
        SensitiveMarkers.register(view, this)
    }

    override fun onDetach() {
        host?.let { SensitiveMarkers.unregister(it, this) }
        host = null
        coordinates = null
    }

    override fun onGloballyPositioned(coordinates: LayoutCoordinates) {
        this.coordinates = coordinates
    }
}

/** Attached [TugboatSensitiveNode]s per Compose host view. Main thread only. */
internal object SensitiveMarkers {
    private val byHost = WeakHashMap<View, MutableSet<TugboatSensitiveNode>>()

    fun register(host: View, node: TugboatSensitiveNode) {
        byHost.getOrPut(host) { LinkedHashSet() } += node
    }

    fun unregister(host: View, node: TugboatSensitiveNode) {
        val nodes = byHost[host] ?: return
        nodes -= node
        if (nodes.isEmpty()) byHost.remove(host)
    }

    /** The placed, attached markers' coordinates under [host]. */
    fun placed(host: View): List<LayoutCoordinates> =
        byHost[host]?.mapNotNull { node -> node.coordinates?.takeIf { it.isAttached } }.orEmpty()
}
