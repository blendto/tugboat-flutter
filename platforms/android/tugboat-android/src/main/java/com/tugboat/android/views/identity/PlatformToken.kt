package com.tugboat.android.views.identity

import android.view.View

/**
 * The identity class of a view: the nearest **platform** class in its
 * superclass chain (`android.*`, which R8 never renames). A custom
 * `MyButton : MaterialButton : AppCompatButton : Button` is `Button`;
 * androidx classes are library code R8 may rename, so a `RecyclerView` is
 * `ViewGroup`. The legacy `android.support.*` library is not platform code.
 * Cached per class.
 */
internal object PlatformToken {
    private val cache = HashMap<Class<*>, Class<*>>()

    fun platformClass(view: View): Class<*> = synchronized(cache) {
        cache.getOrPut(view.javaClass) { nearestPlatformClass(view.javaClass) }
    }

    fun name(view: View): String = platformClass(view).simpleName

    private fun nearestPlatformClass(start: Class<*>): Class<*> {
        var type: Class<*>? = start
        while (type != null) {
            if (isPlatform(type.name)) return type
            type = type.superclass
        }
        return View::class.java
    }

    private fun isPlatform(name: String) = name.startsWith(PLATFORM_PREFIX) && !name.startsWith(SUPPORT_PREFIX)

    private const val PLATFORM_PREFIX = "android."
    private const val SUPPORT_PREFIX = "android.support."
}
