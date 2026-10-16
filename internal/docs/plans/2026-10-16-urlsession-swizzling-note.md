# URLSession: swizzling vs opt-in capture

Status: note for a later user decision · 2026-10-16 · native evidence N2 (Apple)

N2 ships opt-in capture only: `Tugboat.instrumentedSession(...)` (a
delegate-forwarding proxy), `Tugboat.data(for:session:delegate:route:)`, and
`TugboatAlamofire`. Nothing is swizzled. This note compares that with
swizzling, which Datadog and Sentry use.

## How they do it

Summarized from their public docs and source; details move between releases.

- **Datadog** (`dd-sdk-ios` 2.x): `URLSessionInstrumentation.enable(with:
  .init(delegateClass:))`. The app names its delegate class, and Datadog
  swizzles that class's `didFinishCollecting metrics`, `didCompleteWithError`
  and `didReceive data` to observe tasks. It also swizzles `URLSession` task
  creation and `URLSessionTask.resume()` to see tasks without a delegate
  (completion handlers, `async`), and adds trace headers to first-party
  hosts.
- **Sentry** (`sentry-cocoa`, network tracking on by default): swizzles
  `-[NSURLSessionTask resume]` (on every private task class that implements
  it) and the task's state setter, so every task in the process starts and
  ends a span. It reads the status from `task.response`, injects
  `sentry-trace`/`baggage` headers into requests that match
  `tracePropagationTargets`, and reports failed requests from the status.

## What swizzling would add

- `URLSession.shared` and sessions the app makes without our helper.
- Third-party SDKs' requests (ads, analytics, payments, auth), which the
  app can't route through an instrumented session.
- Zero integration work, so coverage doesn't depend on every call site.

Error bodies would still be out of reach for completion-handler and `async`
tasks unless we also wrap their completion handlers, which is the most
invasive kind of swizzle.

## Risks

- **Delegate-proxy conflicts.** Several SDKs swizzle the same delegate
  class or `resume`. Order of installation decides who wraps whom. A
  partner that replaces an IMP without calling the original drops our
  observation, or we drop theirs.
- **iOS changes.** The task classes are private (`__NSCFLocalDataTask`,
  `NSURLSessionTask` subclasses that changed across iOS 13–17), and
  `setState:` is private API. A new class or a Network.framework-based
  loader (`usesClassicLoadingMode`) can silently stop capture or call a
  method twice. Alamofire already sees duplicate metrics callbacks there.
- **Background sessions.** Tasks finish in another process and complete
  after relaunch. Swizzled delegate methods can run before our `start`, so
  they must not hold state or call into the engine early.
- **async APIs.** `data(for:)` uses an internal delegate. We'd see `resume`
  and state changes, but not the body, and the task delegate API (iOS 15)
  adds a second delegate path that each swizzle has to respect.
- **Double instrumentation.** An instrumented session plus a global swizzle
  records each call twice unless tasks are marked and one path defers. The
  same goes for Alamofire, whose tasks are ordinary URLSession tasks.
- **App Store and privacy review.** Swizzling isn't banned, but private
  selectors (`setState:`, private class names) are what review tooling
  flags. Observing every request in the process, including other SDKs'
  requests, needs its own privacy-manifest and disclosure story.
  Third-party traffic may carry data the app never agreed to send us, even
  if all we take is a route and a status.
- **Debugging opacity.** Crashes and behaviour changes surface inside
  URLSession frames with our IMPs in the stack. Host developers can't see
  that Tugboat touches their requests, and "it works without Tugboat" is
  the first thing they try.

## Doing it safely here

- Observe only: never mutate requests. We inject no headers, which removes
  Datadog's and Sentry's riskiest step.
- A separate opt-in product (for example `TugboatAutoNetwork`), never
  default-on in `Tugboat`, with a runtime off switch and a single
  idempotent install.
- Swizzle only `-[NSURLSessionTask resume]` (start time plus a global route
  resolver), and finish from public state: KVO on `state` and the
  `countOfBytes*` and `response`/`error` properties. No private selectors,
  no delegate-class swizzles, and no error bodies.
- Chain to the previous IMP (`method_setImplementation`, keeping the old
  one) so other swizzlers still run, whatever order they install in.
- Exclude Tugboat's own collector session and background sessions. Mark
  tasks from `instrumentedSession`, `Tugboat.data` and `TugboatAlamofire`
  so they're recorded once.
- A test matrix on every supported iOS major (15–26) and on the
  Network.framework loader, plus a canary with Sentry or Datadog installed
  in the same app.

## Recommendation

Keep opt-in as the only shipped path for now. It covers the app's own
networking, which is what Session Atlas needs to explain user-visible
failures. It also keeps the "identical with and without Tugboat"
guarantee and adds no private API.

Revisit swizzling only when a customer needs `URLSession.shared` or
third-party coverage. Then build the observe-only `resume` plus KVO
variant above as a separate opt-in module, with no error bodies and no
header injection, and run the canary before it ships.
