# Capture coverage

Authoritative closed vocabulary and first-milestone mapping:
[native-capture-contracts.md](native-capture-contracts.md) (Coverage).

The Android path reports `engineSurface` for `PixelCopy` of the active
`FlutterSurfaceView`. The Apple plugin reports `engineSurface` when it renders
the live Flutter layer. Neither path is the final window composition.
Platform views and separate video or map surfaces can be missing. Secure or
DRM content can also be missing. Those cases are unsupported modes or missing
layers. They are never an unmasked substitute.

`windowComposite` is Android `PixelCopy` of one app window's surface (API
26+), for native Android hosts; the Flutter plugin does not use it. It holds
the views drawn into that window, `TextureView` included, and is not the
full-screen composition. `SurfaceView` / `GLSurfaceView` layers (video,
camera previews, maps) are missing, so callers mask them fail-closed. Other
windows (dialogs, popups, dropdowns, the IME) are missing too. A
`FLAG_SECURE` window is never copied (`secureWindow`). `viewHierarchy` is an
optional Apple compatibility mode. It uses `drawHierarchy` of the Flutter
view. Incomplete descendants set `incomplete=true`.
