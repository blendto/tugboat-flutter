# The JNI bridge binds native methods by name and constructs
# EngineResponse from C++ (FindClass + <init>(I[B)V).
-keepclasseswithmembernames class com.tugboat.android.engine.NativeEngine {
    native <methods>;
}
-keep class com.tugboat.android.engine.EngineResponse {
    <init>(int, byte[]);
}

# The Views adapter compiles against these androidx libraries but does not
# depend on them; apps without them must not fail R8 on the references.
-dontwarn androidx.core.view.ScrollingView
-dontwarn androidx.fragment.app.**
-dontwarn androidx.recyclerview.widget.**
# It probes them by class name (Class.forName) and recognises Compose hosts
# by class name for fail-closed masks: keep those names when the app keeps
# the classes. -keepnames never forces a class to be kept.
-keepnames class androidx.recyclerview.widget.RecyclerView
-keepnames class androidx.core.view.ScrollingView
-keepnames class androidx.fragment.app.FragmentActivity
-keepnames class androidx.compose.ui.platform.AbstractComposeView
-keepnames class androidx.compose.ui.platform.AndroidComposeView
