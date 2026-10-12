import SwiftUI
import Tugboat

/// The second screen: a `TextField` and a `ScrollView`.
struct DetailScreen: View {
  @State private var note = ""

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 12) {
        TextField("Write a note", text: $note)
          .textFieldStyle(.roundedBorder)
          .tugboatTag("note-field")
        Text("\(note.count) characters")
          .foregroundColor(.secondary)
        ForEach(1...30, id: \.self) { index in
          VStack(alignment: .leading, spacing: 4) {
            Text("Section \(index)")
              .font(.headline)
            Text("Body text that the screenshot masks before it is encoded.")
          }
          .padding()
          .frame(maxWidth: .infinity, alignment: .leading)
          .background(RoundedRectangle(cornerRadius: 10).fill(Color.blue.opacity(0.1)))
        }
      }
      .padding()
    }
    .navigationTitle("Details")
    .tugboatScreen("Details")
  }
}
