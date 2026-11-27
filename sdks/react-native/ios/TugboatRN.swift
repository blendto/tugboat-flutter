import Foundation
import UIKit

@_spi(TugboatAdapters) import Tugboat

/// The Swift side of the React Native module: each method is one call to the
/// same-named `Tugboat` function (as `TugboatModule.kt` on Android). Events
/// are built by the shared engine, never here. Nothing throws or traps into
/// the app; a failure is logged and ignored.
@objc(TugboatRN)
public final class TugboatRN: NSObject {
  // Read on React Native's network queue, written by `start`.
  private static let lock = NSLock()
  private static var capture = false
  private static var allowHosts: Set<String> = []

  /// `config` is what JavaScript passed to `Tugboat.start`.
  @objc public static func start(_ config: NSDictionary) {
    installSeams()
    guard let collector = config["collector"] as? [String: Any],
      let baseUrl = (collector["baseUrl"] as? String).flatMap(URL.init(string:)),
      let apiKey = collector["apiKey"] as? String,
      let app = config["app"] as? [String: Any]
    else {
      NSLog("[TugboatRN] start ignored: collector and app are required")
      return
    }
    let info = Bundle.main.infoDictionary ?? [:]
    func text(_ value: Any?) -> String? {
      (value as? String).flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
    }
    let appInfo = TugboatConfig.App(
      name: text(app["name"]) ?? text(info["CFBundleDisplayName"]) ?? text(info["CFBundleName"]) ?? "",
      version: text(app["version"]) ?? text(info["CFBundleShortVersionString"]) ?? "",
      buildNumber: text(app["buildNumber"]) ?? text(info["CFBundleVersion"]) ?? "",
      appId: text(app["appId"]) ?? Bundle.main.bundleIdentifier ?? "",
      installationId: text(app["installationId"]) ?? "")
    let hosts = (config["networkAllowHosts"] as? [Any])?.compactMap { $0 as? String } ?? []
    lock.lock()
    capture = (config["captureNetwork"] as? Bool) ?? true
    allowHosts = Set(hosts.map { $0.lowercased() })
    lock.unlock()
    Tugboat.start(
      TugboatConfig(
        collector: .init(baseURL: baseUrl, apiKey: apiKey),
        app: appInfo,
        enabled: (config["enabled"] as? Bool) ?? false,
        captureFocusChanges: (config["captureFocusChanges"] as? Bool) ?? false,
        captureDiagnostics: (config["captureDiagnostics"] as? Bool) ?? false,
        // JavaScript names every screen with setScreen; no view controller is a route.
        trackHostingControllers: false,
        durableOutbox: (config["durableOutbox"] as? Bool) ?? false))
  }

  @objc public static func activate(_ activationRequestId: String) {
    Tugboat.activate(activationRequestId: activationRequestId)
  }

  @objc public static func deactivate() {
    Tugboat.deactivate()
  }

  @objc public static func stop() {
    Tugboat.stop()
  }

  @objc public static func setScreen(_ name: String, instanceId: String?) {
    let id = instanceId.flatMap { $0.isEmpty ? nil : $0 } ?? name
    TugboatAdapters.setScreen(name: name, instanceId: id)
  }

  @objc public static func setUserId(_ id: String?) {
    Tugboat.setUserId(id)
  }

  @objc public static func setTraits(_ traits: NSDictionary) {
    var bag: [String: Any] = [:]
    for (key, value) in traits {
      if let key = key as? String { bag[key] = value }
    }
    Tugboat.setTraits(bag)
  }

  /// `<Tugboat.Sensitive>`: the Fabric view calls this on creation (main thread).
  @objc public static func markSensitive(_ view: UIView) {
    TugboatAdapters.markSensitive(view)
  }

  // MARK: Network

  /// True after `start` with `captureNetwork` not false: React Native's HTTP
  /// requests then go through `TugboatHTTPRequestHandler`.
  @objc public static var capturesNetwork: Bool {
    lock.lock()
    defer { lock.unlock() }
    return capture
  }

  /// A session that records each task as `network_call`, with React Native's
  /// own handler as delegate. The route is the URL path (percent-encoded),
  /// never the URL or query; empty `networkAllowHosts` records every host.
  @objc public static func instrumentedSession(
    configuration: URLSessionConfiguration, delegate: URLSessionDelegate, queue: OperationQueue
  ) -> URLSession {
    Tugboat.instrumentedSession(configuration: configuration, delegate: delegate, delegateQueue: queue) { request in
      route(of: request)
    }
  }

  private static func route(of request: URLRequest) -> String? {
    guard let url = request.url else { return nil }
    lock.lock()
    let hosts = allowHosts
    lock.unlock()
    if !hosts.isEmpty, !hosts.contains((url.host ?? "").lowercased()) { return nil }
    let path = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath ?? ""
    return path.isEmpty ? nil : path
  }

  // MARK: React Native views

  private static var installed = false

  /// What the Swift host cannot know about React Native's views: `testID` is
  /// the view's `accessibilityIdentifier`, and its paragraph and image views
  /// draw their own text and pixels, which the screenshot masks.
  private static func installSeams() {
    lock.lock()
    let first = !installed
    installed = true
    lock.unlock()
    guard first else { return }
    TugboatAdapters.setViewNameProvider { $0.accessibilityIdentifier }
    let paragraph = NSClassFromString("RCTParagraphComponentView")
    let image = NSClassFromString("RCTImageComponentView")
    TugboatAdapters.setViewRoleClassifier { cls in
      if let paragraph = paragraph, cls.isSubclass(of: paragraph) { return .text }
      if let image = image, cls.isSubclass(of: image) { return .image }
      return nil
    }
  }
}
