# Interop masking tells Compose's own container and layer views apart from
# AndroidView interop views by package name (InteropViews). Keep those names
# when the app keeps the classes; -keepnames never forces a class to be kept.
# Renamed classes would only over-mask (fail-closed), never under-mask.
-keepnames class androidx.compose.ui.platform.**
-keepnames class androidx.compose.ui.graphics.layer.view.**
