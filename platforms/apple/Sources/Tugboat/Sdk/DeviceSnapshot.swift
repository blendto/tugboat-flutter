import Foundation

/// The device values `session_start` carries, read once at start. Sizes are
/// points (logical pixels), as Flutter's `TugboatCollectorHost.fromPlatform`
/// reports them on iOS.
struct DeviceSnapshot: Equatable {
  /// `identifierForVendor`, or `ios-unknown` like Flutter's
  /// `device_info_plus` fallback.
  let id: String
  let model: String?
  let osVersion: String?
  let screenWidth: Double
  let screenHeight: Double
  /// `UIScreen.scale`: physical pixels per point.
  let scale: Double
  let locale: LocaleSnapshot
  /// The configured locale's timezone, as Dart's `timeZoneName` (an
  /// abbreviation such as `GMT+5:30`), else the zone identifier.
  let timezone: String

  /// Flutter's `screenDpi`: `(devicePixelRatio * 160).round()`.
  var screenDpi: Int {
    let dpi = (scale * 160).rounded()
    return dpi.isFinite && dpi > 0 && dpi < 100_000 ? Int(dpi) : 0
  }
}

/// The active app locale as `TugboatLocaleInfo`: `language` and `tag`
/// required, `country` and `script` when known.
struct LocaleSnapshot: Equatable {
  let language: String
  let country: String?
  let script: String?

  /// BCP 47: `language[-Script][-COUNTRY]`.
  var tag: String {
    [language, script, country].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "-")
  }

  static func of(_ locale: Locale) -> LocaleSnapshot {
    LocaleSnapshot(
      language: locale.languageCode ?? "",
      country: nonEmpty(locale.regionCode),
      script: nonEmpty(locale.scriptCode)
    )
  }

  private static func nonEmpty(_ value: String?) -> String? {
    guard let value = value, !value.isEmpty else { return nil }
    return value
  }
}

#if canImport(UIKit)
import UIKit

extension DeviceSnapshot {
  /// Main thread only (`UIScreen`, `UIDevice`).
  static func read(screen: UIScreen = .main, device: UIDevice = .current) -> DeviceSnapshot {
    let bounds = screen.bounds
    return DeviceSnapshot(
      id: device.identifierForVendor?.uuidString ?? "ios-unknown",
      model: device.model,
      osVersion: device.systemVersion,
      screenWidth: Double(bounds.width),
      screenHeight: Double(bounds.height),
      scale: Double(screen.scale),
      locale: LocaleSnapshot.of(Locale.autoupdatingCurrent),
      timezone: TimeZone.current.abbreviation() ?? TimeZone.current.identifier
    )
  }
}
#endif
