import SwiftUI
import Tugboat
import UIKit

@main
struct SampleApp: App {
  @UIApplicationDelegateAdaptor(SampleAppDelegate.self) private var delegate

  var body: some Scene {
    WindowGroup {
      NavigationContainer {
        if UserDefaults.standard.bool(forKey: "TugboatAccessibilityFixture") {
          AccessibilityFixtureScreen()
        } else {
          HomeScreen()
        }
      }
      .onOpenURL { SampleConfiguration.handle($0) }
    }
  }
}

/// Starts Tugboat at launch, before the first scene connects, so the first
/// key window is observed and the session's first capture finds it.
final class SampleAppDelegate: NSObject, UIApplicationDelegate {
  func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
  ) -> Bool {
    if let config = SampleConfiguration.tugboat() {
      Tugboat.start(config)
    }
    if let id = SampleConfiguration.activationRequestId() {
      Tugboat.activate(activationRequestId: id)
    }
    Tugboat.setTraits(["sample": "swiftui"])
    return true
  }
}
