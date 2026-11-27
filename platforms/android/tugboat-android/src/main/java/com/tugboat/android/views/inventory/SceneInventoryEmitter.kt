package com.tugboat.android.views.inventory

import android.os.Looper
import android.util.Log
import android.view.Window
import android.view.WindowManager
import com.tugboat.android.views.facts.FactClock
import com.tugboat.android.views.facts.FactTypes
import com.tugboat.android.views.facts.ViewsFact
import com.tugboat.android.views.identity.RouteResolver
import org.json.JSONObject

/**
 * When `scene.inventory` facts leave (`TugboatConfig.emitSceneInventory`):
 * after each captured frame, for the route of the visible content, labelled
 * with the moment the capture was taken for (`trigger`), and on the engine's
 * `scene.sample` (the settled re-sample, stateful-engine.md section 4.3.2),
 * which has no label: the engine stamps it. Route changes need no trigger of
 * their own: the engine's post-navigation route capture is a captured frame.
 *
 * - A `FLAG_SECURE` window has no inventory.
 * - The route is resolved first; when the frame's structure signature (the
 *   one its masks were computed from) equals the last emitted inventory's for
 *   that route, nothing is walked, unless the caller says the engine needs the
 *   fact (the re-sample watch is not armed, or the frame is a tap, gesture or
 *   scroll moment). Never for a frame whose window had region
 *   hosts (Compose): the signature does not see their content, so those are
 *   walked on every captured frame (the capture cadence and budget bound it).
 *   Views-only gap: a view that only becomes clickable changes no signature.
 * - The signature is stored only once a non-empty inventory was emitted.
 * - A page with nothing to list is still reported (an empty inventory) when
 *   the engine needs the fact, so its watch is armed and the content that
 *   loads later is sampled.
 *
 * Main thread only: called elsewhere, it logs and drops the frame.
 */
internal class SceneInventoryEmitter(
    private val routes: RouteResolver,
    private val builder: SceneInventoryBuilder,
    private val clock: FactClock,
    /** Hands the fact to the batcher; false once the adapter has stopped. */
    private val emit: (ViewsFact) -> Boolean,
) {
    private val lastStructureByRoute = HashMap<String, String>()

    /**
     * A capture of [window] completed. [trigger] is the `scene_inventory.trigger`
     * of its inventory; [mayReuse] lets an unchanged structure skip the walk.
     */
    fun onCapturedFrame(
        window: Window,
        structureSignature: String,
        hasRegionHosts: Boolean,
        trigger: String? = null,
        mayReuse: Boolean = true,
    ) {
        val decor = visibleDecor(window) ?: return
        val route = routes.visibleRoute(decor) ?: return
        if (mayReuse && !hasRegionHosts && lastStructureByRoute[route.value] == structureSignature) return
        val inventory = builder.build(decor, route.value)
        if (inventory == null) {
            // Nothing to list yet: tell the engine so it watches the page.
            emitEmpty(route.value, trigger, InventoryMetadata.surface(window))
            return
        }
        val input = inventory.toJson(trigger = trigger, surface = InventoryMetadata.surface(window))
        if (emit(ViewsFact(FactTypes.SCENE_INVENTORY, input, clock.now()))) {
            lastStructureByRoute[route.value] = structureSignature
        }
    }

    /**
     * The engine asked for a sample (`scene.sample`): the visible route's
     * inventory of [window], marked `resample`. Sends nothing when there is
     * none: the engine treats no answer as nothing new.
     */
    fun onSample(window: Window) {
        val decor = visibleDecor(window) ?: return
        val route = routes.visibleRoute(decor) ?: return
        val inventory = builder.build(decor, route.value) ?: return
        val input = inventory.toJson(surface = InventoryMetadata.surface(window), resample = true)
        emit(ViewsFact(FactTypes.SCENE_INVENTORY, input, clock.now()))
    }

    private fun emitEmpty(routeKey: String, trigger: String?, surface: JSONObject) {
        val input = JSONObject().put("routeKey", routeKey).put("elements", org.json.JSONArray()).put("surface", surface)
        if (trigger != null) input.put("trigger", trigger)
        emit(ViewsFact(FactTypes.SCENE_INVENTORY, input, clock.now()))
    }

    private fun visibleDecor(window: Window): android.view.View? {
        if (Looper.myLooper() != Looper.getMainLooper()) {
            Log.w(TAG, "scene inventory off the main thread; dropped")
            return null
        }
        if (window.attributes.flags and WindowManager.LayoutParams.FLAG_SECURE != 0) return null
        return window.decorView
    }

    private companion object {
        const val TAG = "TugboatViews"
    }
}
