package androidx.compose.ui.platform

import android.content.Context
import android.widget.FrameLayout

/**
 * Test stand-ins with Compose's real class names: tugboat-android has no
 * Compose dependency and recognises Compose hosts by name only.
 */
abstract class AbstractComposeView(context: Context) : FrameLayout(context)

class ComposeView(context: Context) : AbstractComposeView(context)
