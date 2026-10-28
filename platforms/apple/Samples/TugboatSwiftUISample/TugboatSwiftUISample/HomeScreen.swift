import SwiftUI
import Tugboat

/// The first screen: a tagged button, a swipe area, a link to the second
/// screen, a stop button, a coded event and a network call, and a `List`.
struct HomeScreen: View {
  @State private var cartCount = 0
  @State private var stopped = false

  var body: some View {
    VStack(spacing: 12) {
      HStack {
        Image(systemName: "shippingbox.fill")
          .foregroundColor(.accentColor)
        Text("Items in cart: \(cartCount)")
          .font(.headline)
        Spacer()
      }
      .padding(.horizontal)

      Button("Add to cart") { cartCount += 1 }
        .buttonStyle(.borderedProminent)
        .tugboatTag("add-to-cart")

      SwipeArea()
        .padding(.horizontal)

      NavigationLink("Open details", destination: DetailScreen())
        .tugboatTag("open-details")

      Button(stopped ? "Tugboat stopped" : "Stop Tugboat") {
        Tugboat.stop()
        stopped = true
      }
      .disabled(stopped)
      .tugboatTag("stop-tugboat")

      EvidenceDemo()

      List(1...60, id: \.self) { row in
        HStack {
          Image(systemName: row.isMultiple(of: 2) ? "star.fill" : "circle")
          Text("Row \(row)")
          Spacer()
          Text("$\(row * 3).00")
            .foregroundColor(.secondary)
        }
      }
      .listStyle(.plain)
    }
    .navigationTitle("Home")
    .tugboatScreen("Home")
  }
}

/// A card that reports horizontal swipes.
struct SwipeArea: View {
  @State private var lastSwipe = "Swipe here"

  var body: some View {
    RoundedRectangle(cornerRadius: 12)
      .fill(Color.orange.opacity(0.3))
      .frame(height: 90)
      .overlay(Text(lastSwipe))
      .contentShape(Rectangle())
      .gesture(
        DragGesture(minimumDistance: 20)
          .onEnded { value in
            lastSwipe = value.translation.width < 0 ? "Swiped left" : "Swiped right"
          }
      )
      .tugboatTag("swipe-area")
  }
}
