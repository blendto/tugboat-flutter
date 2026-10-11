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
/// text, a button, a text field, an image, and a list. `probeFrame` records
/// each element's real on-screen frame as ground truth for the layer pass.
struct ProbeScreen: View {
  @State private var name = ""
  @State private var report = "Probe running…"

  var body: some View {
    NavigationView {
      VStack(alignment: .leading, spacing: 12) {
        Text("Probe heading")
          .font(.headline)
          .probeFrame("text.heading")
        Button {
        } label: {
          Text("Probe button")
            .probeFrame("text.button")
        }
        .accessibilityIdentifier("probe.button")
        TextField("Probe field", text: $name)
          .textFieldStyle(.roundedBorder)
          .accessibilityIdentifier("probe.field")
          .probeFrame("field")
        Image(systemName: "star.fill")
          .accessibilityLabel("Probe image")
          .probeFrame("image.star")
        List(0..<20, id: \.self) { row in
          Text("Row \(row)")
            .probeFrame("text.row\(row)")
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
      ProbeLog.reset()
      var summaries: [String] = []
      // Two passes: the tree may be built lazily after first layout.
      for delaySeconds in [0.5, 2.0] {
        try? await Task.sleep(nanoseconds: UInt64(delaySeconds * 1_000_000_000))
        let summary = await MainActor.run { () -> String in
          let result = Probe.run(label: "t+\(delaySeconds)s")
          ProbeLog.emit(result.full)
          return result.summary
        }
        summaries.append(summary)
        let text = summaries.joined(separator: "\n")
        await MainActor.run { report = text }
      }
    }
  }
}

/// Ground-truth frames in window (global) coordinates, keyed by probe name.
enum ProbeFrames {
  static var frames: [String: CGRect] = [:]
}

extension View {
  func probeFrame(_ name: String) -> some View {
    background(
      GeometryReader { geometry in
        Color.clear
          .onAppear { ProbeFrames.frames[name] = geometry.frame(in: .global) }
          .onChange(of: geometry.frame(in: .global)) { frame in
            ProbeFrames.frames[name] = frame
          }
      }
    )
  }
}

/// Prints each pass and flushes stdout so a killed app still delivers both
/// passes, and mirrors everything to Documents/a11y-probe.log.
enum ProbeLog {
  static var fileURL: URL? {
    FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?
      .appendingPathComponent("a11y-probe.log")
  }

  static func reset() {
    guard let url = fileURL else { return }
    try? Data().write(to: url)
    print("A11YPROBE log file: \(url.path)")
    fflush(stdout)
  }

  static func emit(_ text: String) {
    print(text)
    fflush(stdout)
    guard let url = fileURL, let data = (text + "\n").data(using: .utf8),
      let handle = try? FileHandle(forWritingTo: url)
    else { return }
    handle.seekToEndOfFile()
    handle.write(data)
    handle.closeFile()
  }
}
