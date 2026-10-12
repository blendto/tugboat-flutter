package io.flutter.embedding.android

import android.content.Context
import android.view.SurfaceView

/**
 * Test stand-in for Flutter's engine surface. `EngineSurfaceFinder` matches by
 * class name, so the runtime never depends on the Flutter embedding.
 */
class FlutterSurfaceView(
    context: Context,
) : SurfaceView(context)
