package com.tugboat.android.views.navigation

/** Navigation route patterns without their arguments: the one route-key normalization. */
internal object RoutePattern {
    /**
     * `checkout/{id}?step={s}` becomes `checkout`; a type-safe route
     * `com.example.Profile/{id}` becomes `com.example.Profile`. Null when
     * nothing is left.
     */
    fun strip(route: String?): String? {
        val path = route?.substringBefore('?') ?: return null
        return path.split('/')
            .filter { it.isNotEmpty() && !it.contains('{') }
            .joinToString(separator = "/")
            .takeIf { it.isNotEmpty() }
    }
}
