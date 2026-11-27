#if canImport(UIKit)
import UIKit

/// The marker for one `.tugboatTag` view: its frame, window and hosting
/// root are read from UIKit at tap time. Masks and identity skip it and its
/// host (`ViewKind.sdkOwned`).
final class TagMarkerView: MarkerView {
  var tugboatTag = ""
  weak var registry: TagRegistry?
}
#endif
