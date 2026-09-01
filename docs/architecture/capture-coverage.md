# Capture coverage

Authoritative closed vocabulary and first-milestone mapping:
[native-capture-contracts.md](native-capture-contracts.md) (Coverage).

The first Android path reports `engineSurface` only. That is a
`PixelCopy` of the active `FlutterSurfaceView`, not the final SurfaceFlinger
composition. Platform views, separate video or map surfaces, `FLAG_SECURE` /
DRM, `FlutterTextureView`, and hybrid composition can be missing. Those cases
are `unsupportedRenderMode` or incomplete layers. They are never an unmasked
substitute.

`windowComposite` is forbidden until that path exists. `viewHierarchy` is
the Apple CPU path: `drawHierarchy` of the Flutter view. Incomplete
descendants set `incomplete=true`.
