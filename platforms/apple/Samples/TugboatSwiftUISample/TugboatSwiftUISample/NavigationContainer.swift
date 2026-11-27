import SwiftUI

/// `NavigationStack` on iOS 16 and later, a stack-style `NavigationView` on
/// iOS 15.
struct NavigationContainer<Content: View>: View {
  @ViewBuilder let content: () -> Content

  var body: some View {
    if #available(iOS 16.0, *) {
      NavigationStack(root: content)
    } else {
      NavigationView(content: content)
        .navigationViewStyle(.stack)
    }
  }
}
