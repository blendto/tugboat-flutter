# Third-party notices

The repository is AGPL-3.0-only. First native CPU capture does not vendor
`libjpeg-turbo` or other codecs; Android and Apple platform JPEG are used
instead ([ADR 0004](../decisions/0004-platform-jpeg.md)).

## Vendored native code

| Name | Version | License | Source | Location |
| --- | --- | --- | --- | --- |
| double-conversion | 3.3.0 (`4f7a25d8ced8c7cf6eee6fd09d6788eaa23c9afe`) | BSD-3-Clause | https://github.com/google/double-conversion | `core/session-engine/third_party/double-conversion` (namespace renamed to `tb_double_conversion`) |

The session engine is not linked into a published artifact yet. When it
ships inside `capture-runtime` or `TugboatCaptureRuntime`, that artifact
must carry the double-conversion notice.

When a vendored native library is added:

1. Record the name, version, license, and source URL in this file.
2. Keep the notice in the AAR / CocoaPod / Swift package that ships the
   binary.
3. Do not copy notices only into the Flutter pub package if the native
   artifact is what contains the code.
