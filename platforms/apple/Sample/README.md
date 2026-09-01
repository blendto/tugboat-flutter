# Apple capture sample

Minimal usage of `TugboatCaptureRuntime`. This is not a full Xcode
application; open the repository root in Xcode as a Swift package, or add
the CocoaPod via:

```ruby
pod 'TugboatCaptureRuntime', :path => '.'
```

from the monorepo root.

Apple view capture must run on the main thread. The runtime hops to main for
that step, then masks, hashes, and encodes on its serial capture queue. The
default `CaptureCoverage.engineSurface` renders the live Flutter layer.
Select `.viewHierarchy` only when UIKit platform-view coverage is required.

Do not log JPEG or pixel buffers. Do not publish this 0.1.0 artifact until
device privacy rows pass.
