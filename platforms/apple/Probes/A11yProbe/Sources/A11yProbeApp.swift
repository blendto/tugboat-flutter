import SwiftUI

@main
struct A11yProbeApp: App {
  var body: some Scene {
    WindowGroup {
      ProbeScreen()
    }
  }
}

/// One of each element the SwiftUI adapter must identify or mask: heading
/// text, a button, a text field, an image, and a list.
struct ProbeScreen: View {
  @State private var name = ""
  @State private var report = "Probe running…"

  var body: some View {
    NavigationView {
      VStack(alignment: .leading, spacing: 12) {
        Text("Probe heading")
          .font(.headline)
        Button("Probe button") {}
          .accessibilityIdentifier("probe.button")
        TextField("Probe field", text: $name)
          .textFieldStyle(.roundedBorder)
          .accessibilityIdentifier("probe.field")
        Image(systemName: "star.fill")
          .accessibilityLabel("Probe image")
        List(0..<20, id: \.self) { row in
          Text("Row \(row)")
        }
        .frame(height: 220)
        .accessibilityIdentifier("probe.list")
        ScrollView {
          Text(report)
            .font(.system(.caption2, design: .monospaced))
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: 140)
      }
      .padding()
      .navigationTitle("A11y probe")
    }
    .navigationViewStyle(.stack)
    .task {
      var summaries: [String] = []
      // Two passes: the tree may be built lazily after first layout.
      for delaySeconds in [0.5, 2.0] {
        try? await Task.sleep(nanoseconds: UInt64(delaySeconds * 1_000_000_000))
        let summary = await MainActor.run { () -> String in
          let result = Probe.run(label: "t+\(delaySeconds)s")
          print(result.full)
          return result.summary
        }
        summaries.append(summary)
        let text = summaries.joined(separator: "\n")
        await MainActor.run { report = text }
      }
    }
  }
}
