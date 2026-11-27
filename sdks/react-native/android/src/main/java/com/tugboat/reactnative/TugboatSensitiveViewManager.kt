package com.tugboat.reactnative

import com.facebook.react.uimanager.ThemedReactContext
import com.facebook.react.uimanager.ViewGroupManager
import com.facebook.react.uimanager.ViewManagerDelegate
import com.facebook.react.viewmanagers.TugboatSensitiveViewManagerDelegate
import com.facebook.react.viewmanagers.TugboatSensitiveViewManagerInterface
import com.facebook.react.views.view.ReactViewGroup
import com.tugboat.android.tugboatSensitive

/** `<Tugboat.Sensitive>`: a plain view the Views adapter masks with its whole subtree. */
class TugboatSensitiveViewManager :
    ViewGroupManager<ReactViewGroup>(),
    TugboatSensitiveViewManagerInterface<ReactViewGroup> {
    private val delegate = TugboatSensitiveViewManagerDelegate(this)

    override fun getDelegate(): ViewManagerDelegate<ReactViewGroup> = delegate

    override fun getName(): String = NAME

    override fun createViewInstance(context: ThemedReactContext): ReactViewGroup =
        ReactViewGroup(context).also { view ->
            try {
                view.tugboatSensitive()
            } catch (_: Throwable) {
                // Never throw into the app.
            }
        }

    companion object {
        const val NAME = "TugboatSensitiveView"
    }
}
