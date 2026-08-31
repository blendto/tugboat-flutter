# Third-party notices

The repository is AGPL-3.0-only. First native CPU capture does not vendor
`libjpeg-turbo` or other codecs; Android and Apple platform JPEG are used
instead ([ADR 0004](../decisions/0004-platform-jpeg.md)).

When a vendored native library is added:

1. Record the name, version, license, and source URL in this file.
2. Keep the notice in the AAR / CocoaPod / Swift package that ships the
   binary.
3. Do not copy notices only into the Flutter pub package if the native
   artifact is what contains the code.
