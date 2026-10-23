/// The engine's `engine.configure.host` group and the session locale: every
/// field the collector requires on `session_start` (native SDK note section
/// 7). The collector answers 400 to a `session_start` without them and the
/// session is lost, so `missingFields` must be empty before a session
/// starts.
struct HostMetadata {
  static let platform = "ios"
  /// `ipInfo.ip` is required but the device cannot know its public address.
  /// Flutter's iOS host sends the loopback as a placeholder, and so does
  /// this one (the collector may enrich it from the request).
  static let placeholderIP = "127.0.0.1"

  let app: TugboatConfig.App
  let device: DeviceSnapshot

  /// Required fields that are blank or out of range, by wire path; empty
  /// when complete.
  var missingFields: [String] {
    var missing: [String] = []
    func text(_ path: String, _ value: String?) {
      if (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { missing.append(path) }
    }
    func positive(_ path: String, _ value: Double) {
      if !(value > 0) || !value.isFinite { missing.append(path) }
    }
    text("app.name", app.name)
    text("app.version", app.version)
    text("app.buildNumber", app.buildNumber)
    text("app.appId", app.appId)
    text("app.installationId", app.installationId)
    text("device.id", device.id)
    positive("device.screenSize.width", device.screenWidth)
    positive("device.screenSize.height", device.screenHeight)
    positive("device.screenDensity", device.scale)
    positive("device.screenDpi", Double(device.screenDpi))
    text("locale.language", device.locale.language)
    return missing
  }

  /// `engine.configure.host`.
  var hostJSON: JSONObject {
    var ip = JSONObject()
    ip.set("ip", HostMetadata.placeholderIP)
    var out = JSONObject()
    out.set("app", appJSON)
    out.set("device", deviceJSON)
    out.set("ip", ip)
    out.set("locale", configuredLocaleJSON)
    return out
  }

  /// `session.start.locale` (`TugboatLocaleInfo`).
  var sessionLocaleJSON: JSONObject {
    let locale = device.locale
    var out = JSONObject()
    out.set("language", locale.language)
    if let country = locale.country { out.set("country", country) }
    if let script = locale.script { out.set("script", script) }
    out.set("tag", locale.tag)
    return out
  }

  private var appJSON: JSONObject {
    var out = JSONObject()
    out.set("name", app.name)
    out.set("version", app.version)
    out.set("buildNumber", app.buildNumber)
    out.set("installationId", app.installationId)
    out.set("appId", app.appId)
    return out
  }

  /// Screen metrics are doubles on the wire except `screenDpi` (an
  /// integer); the engine prints doubles like Dart (`390.0`).
  private var deviceJSON: JSONObject {
    var size = JSONObject()
    size.set("width", .double(device.screenWidth))
    size.set("height", .double(device.screenHeight))
    var out = JSONObject()
    out.set("id", device.id)
    out.set("platform", HostMetadata.platform)
    if let model = device.model { out.set("model", model) }
    if let osVersion = device.osVersion { out.set("osVersion", osVersion) }
    out.set("screenSize", size)
    out.set("screenDensity", .double(device.scale))
    out.set("screenDpi", Int64(device.screenDpi))
    out.set("screenPixelDensity", .double(device.scale))
    return out
  }

  /// The configured locale (`TugboatCollectorLocaleInfo`): language,
  /// country, timezone.
  private var configuredLocaleJSON: JSONObject {
    var out = JSONObject()
    out.set("language", device.locale.language)
    if let country = device.locale.country { out.set("country", country) }
    out.set("timezone", device.timezone)
    return out
  }
}
