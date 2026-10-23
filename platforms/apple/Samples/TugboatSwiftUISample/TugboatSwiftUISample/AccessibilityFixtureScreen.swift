import SwiftUI
import Tugboat

/// The UI-test screen for `.tugboatTag(_:accessibility:)`, shown instead of
/// Home only when launched with `-TugboatAccessibilityFixture YES`
/// (`TugboatSwiftUISampleUITests`). Each tagged control has an untagged
/// twin with the same label, so the tests compare what the accessibility
/// tree reports for both.
struct AccessibilityFixtureScreen: View {
  @State private var taggedAlerts = false
  @State private var twinAlerts = false
  @State private var taggedName = ""
  @State private var twinName = ""

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 8) {
        Button("Pay") {}
          .tugboatTag("a11y.pay", accessibility: true)
        Button("Pay") {}

        Toggle("Alerts", isOn: $taggedAlerts)
          .tugboatTag("a11y.alerts", accessibility: true)
        Toggle("Alerts", isOn: $twinAlerts)

        TextField("Name", text: $taggedName)
          .textFieldStyle(.roundedBorder)
          .tugboatTag("a11y.name", accessibility: true)
        TextField("Name", text: $twinName)
          .textFieldStyle(.roundedBorder)

        NavigationLink("Details", destination: Text("Details"))
          .tugboatTag("a11y.details", accessibility: true)
        NavigationLink("Details", destination: Text("Details"))

        // A tagged container.
        VStack {
          Button("First") {}
          Button("Second") {}
        }
        .tugboatTag("a11y.group", accessibility: true)

        // App identifiers on either side of the tag.
        Button("Before") {}
          .accessibilityIdentifier("app.before")
          .tugboatTag("a11y.before", accessibility: true)
        Button("After") {}
          .tugboatTag("a11y.after", accessibility: true)
          .accessibilityIdentifier("app.after")

        // The default: no identifier.
        Button("Plain") {}
          .tugboatTag("a11y.plain")
      }
      .padding()
    }
    .navigationTitle("Accessibility")
    .tugboatScreen("AccessibilityFixture")
  }
}
