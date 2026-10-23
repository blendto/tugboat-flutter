package com.tugboat.android.views.inventory

import android.os.Looper
import android.util.Log
import android.view.Window
import android.view.WindowManager
import com.tugboat.android.views.facts.FactClock
import com.tugboat.android.views.facts.FactTypes
import com.tugboat.android.views.facts.ViewsFact
import com.tugboat.android.views.identity.RouteResolver

/**
 * When `scene.inventory` facts leave (`TugboatConfig.emitSceneInventory`):
 * after each captured frame, for the route of the visible content. Route
 * changes need no trigger of their own: the engine's post-navigation route
 * capture is a captured frame.
 *
 * - A `FLAG_SECURE` window has no inventory.
 * - The route is resolved first; when the frame's structure signature (the
 *   one its masks were computed from) equals the last emitted inventory's for
 *   that route, nothing is walked.
 * - The signature is stored only once a non-empty inventory was emitted.
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

    fun onCapturedFrame(window: Window, structureSignature: String) {
        if (Looper.myLooper() != Looper.getMainLooper()) {
            Log.w(TAG, "scene inventory off the main thread; dropped")
            return
        }
        if (window.attributes.flags and WindowManager.LayoutParams.FLAG_SECURE != 0) return
        val decor = window.decorView
        val route = routes.visibleRoute(decor) ?: return
        if (lastStructureByRoute[route.value] == structureSignature) return
        val inventory = builder.build(decor, route) ?: return
        if (emit(ViewsFact(FactTypes.SCENE_INVENTORY, inventory.toJson(), clock.now()))) {
            lastStructureByRoute[route.value] = structureSignature
        }
    }

    private companion object {
        const val TAG = "TugboatViews"
    }
}
