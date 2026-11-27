# React Native spike probes (BLE-681)

Working note. Code snippets behind the "Spike results" in the
[React Native design note](2026-11-27-react-native-adapter-design-note.md)
(section 15.1). The throwaway apps live outside the repo; these are the parts worth
reusing in the BLE-644 and BLE-669 tests. Probes read React internals and are
written for React Native 0.88 / React 19.3. They are not production code.

## Touched fiber (S1)

```js
// RN <= 0.80 had event._targetInst. On 0.88 it is gone; event.target is a
// ReactNativeElement with own keys __nativeTag, __internalInstanceHandle, __viewConfig.
function fiberFromRef(ref) {
  const r = ref && ref.current;
  if (!r) return null;
  for (const k of ['__internalInstanceHandle', '_internalInstanceHandle'])
    if (r[k] && r[k].tag !== undefined) return r[k];
  return null;
}
function targetFiber(e, appRoot) {
  if (e._targetInst) return {inst: e._targetInst, via: '_targetInst'};
  const f = e.target && fiberFromRef({current: e.target});
  if (f) return {inst: f, via: 'target.internalInstanceHandle'};
  // last resort: walk the committed tree for the host fiber whose tag equals
  // e.nativeEvent.target (tag = fiber.stateNode.canonical.*nativeTag)
  return {inst: null, via: 'none'};
}
```

Attach it with `onTouchStartCapture` on a root `View collapsable={false}`.

## Route context walk (S2)

```js
// React 19: provider fiber has tag 10 and type === the Context object.
// React 18: type._context. Compare by reference, no names.
function providerContext(f) {
  if (f.tag !== 10) return null;
  const t = f.type;
  if (t && t._context) return t._context;      // React 18 shape (not run)
  if (t && t.$$typeof) return t;               // React 19 shape
  return null;
}
// for each fiber up the .return chain:
//   if (providerContext(f) === NavigationRouteContext) names.unshift(f.memoizedProps.value.name)
// Observed Main/Main/Feed for Main(stack) > Feed(tab): collapse repeats by route.key.
```

## List cells (S4)

```js
// FlatList: CellRenderer fiber props {cellKey, index, item, prevCellKey, ...}
const isFlatListCell = p => typeof p.index === 'number' && 'cellKey' in p;
// FlashList 2 (from source, not run): ViewHolder props {index, item, layout,
// refHolder, target: 'Cell', renderItem, extraData}
```

## Custom Fabric mask view (S5)

An autolinked library with codegen (`codegenConfig` type `components`), one prop
`dumpSeq: Int32`.

- JS: `codegenNativeComponent<NativeProps>('TugboatMaskView')`; two wrappers, one
  with `collapsable={false}` and one without.
- iOS: `TugboatMaskView : RCTViewComponentView`,
  `componentDescriptorProvider` returns
  `concreteComponentDescriptorProvider<TugboatMaskViewComponentDescriptor>()`, and
  `Class<RCTComponentViewProtocol> TugboatMaskViewCls(void)` registers it. On a
  `dumpSeq` change it writes the key window's native view tree (class, `tag`, frame in
  window coordinates, `accessibilityIdentifier`) to a file in `/private/tmp`. A tag in
  that dump equals the JS `__nativeTag`.
- iOS touch observer: a `UIGestureRecognizer` on the window
  (`cancelsTouchesInView = NO`) logs `touch.timestamp * 1000`, the hit view class and
  `tag`; compared with JS `nativeEvent.timestamp` (S7).
- Android: `ViewGroupManager<ReactViewGroup>` implementing the codegen
  `TugboatMaskViewManagerInterface`, `getDelegate()` returning
  `TugboatMaskViewManagerDelegate`, and a `ReactPackage` returning the manager.

## Network (the narrowed scope)

```kotlin
// Application.onCreate, before the first request
NetworkingModule.setCustomClientBuilder(CustomClientBuilder { builder ->
  builder.addInterceptor { chain ->
    val req = chain.request()
    Log.i("SpikeOkHttp", "REQ ${req.method} ${req.url}")
    chain.proceed(req).also { Log.i("SpikeOkHttp", "RES ${it.code} ${req.url}") }
  }
})
```

```js
// JS: fetch rides on XMLHttpRequest, so wrapping XHR sees both
const open = XMLHttpRequest.prototype.open, send = XMLHttpRequest.prototype.send;
XMLHttpRequest.prototype.open = function (m, u) { this.__s = {m, u: String(u)}; return open.apply(this, arguments); };
XMLHttpRequest.prototype.send = function () {
  this.addEventListener('loadend', () => log({...this.__s, status: this.status, responseURL: this.responseURL}));
  return send.apply(this, arguments);
};
```

## Driving the apps

- **Android phone:** `adb -s <serial> install -r app-release.apk`; taps with
  `adb shell input tap x y` and `input swipe`; coordinates from
  `adb shell uiautomator dump /data/local/tmp/x.xml` (a `testID` is the node's
  `resource-id`); native classes and React tags from `adb shell dumpsys activity top`
  (the `#hex` id is the React tag); results from `adb logcat -s ReactNativeJS`. Logcat
  truncates long lines and rotates quickly, so the probe logs in 3000-character parts
  and a capture must run while the taps happen.
- **iOS simulator:** an XCUITest target added with the CocoaPods `xcodeproj` gem
  taps by `accessibilityIdentifier` (= `testID`) and swipes; the probe posts JSON to a
  localhost collector.
- Build flags used on Android: `-PreactNativeArchitectures=arm64-v8a`, `compileSdk 36`,
  build-tools 36.0.0, NDK 28.2 (the SDK already on the machine; nothing was installed).
