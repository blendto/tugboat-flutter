# tugboat_http

Record requests from `package:http` in an active Tugboat session. Use
`TugboatHttpClient` wherever your app accepts an `http.Client`.

```dart
import 'package:http/http.dart' as http;
import 'package:tugboat_http/tugboat_http.dart';

final client = TugboatHttpClient(
  http.Client(),
  routeResolver: (url) {
    if (url.host == 'api.example.com' &&
        url.pathSegments.length == 2 &&
        url.pathSegments.first == 'orders') {
      return '/orders/:id';
    }
    return null;
  },
);
```

Send requests through this instance and call `client.close()` when finished.
The wrapper owns the inner client. To observe one call across retries, pass
your configured retry client as the inner client. Top-level `http.get` and
other clients bypass this wrapper.

The resolver runs only while Tugboat accepts evidence. Return a bounded
absolute route or `null` to skip the request. Prefer route templates to keep
identifiers out of evidence. Tugboat records the method, route, duration to
response headers, and either the HTTP status or a transport failure outcome.
An aborted send records cancellation. Headers and bodies, including HTTP
error bodies, stay out of evidence. The caller receives the original response
stream and handles any errors that occur while reading it.
