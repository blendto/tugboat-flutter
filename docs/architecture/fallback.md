# Native capture fallback

Authoritative status × fallback × publish table:
[native-capture-contracts.md](native-capture-contracts.md).

Fallback is one-way for a `requestId`. Native and Flutter never publish the
same request. After fallback starts, a Dart failure is the outcome; do not
retry native for that id.

After three consecutive fallback statuses, native capture disables for the
rest of the session. Session start, activity recreate, and app resume reset
that streak. Cancellation and disposal do not fall back.

Host apps keep `flutterRepaintBoundary` as the default. See
[native-cpu-experimental.md](../integration/native-cpu-experimental.md).
