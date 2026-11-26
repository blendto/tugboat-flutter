import Foundation

/// The seam between the host and one engine handle. Implementations are not
/// thread-safe: the host calls them from its engine queue only.
protocol EngineTransport: AnyObject {
  /// Submits one UTF-8 JSON message and returns the engine's answer.
  func submit(_ message: Data) -> EngineResponse

  /// Releases the handle. Later submits answer `invalidArgument`.
  func close()
}
