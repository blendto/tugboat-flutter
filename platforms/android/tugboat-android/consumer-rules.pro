# The JNI bridge binds native methods by name and constructs
# EngineResponse from C++ (FindClass + <init>(I[B)V).
-keepclasseswithmembernames class com.tugboat.android.engine.NativeEngine {
    native <methods>;
}
-keep class com.tugboat.android.engine.EngineResponse {
    <init>(int, byte[]);
}
