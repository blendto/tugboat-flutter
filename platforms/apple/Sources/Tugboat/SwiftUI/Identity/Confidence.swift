/// Fingerprint confidence tiers, lowest first; `floor` takes the weakest.
enum Confidence: Int, Comparable {
  case low
  case medium
  case high

  var wire: String {
    switch self {
    case .low: return "low"
    case .medium: return "medium"
    case .high: return "high"
    }
  }

  static func < (lhs: Confidence, rhs: Confidence) -> Bool {
    lhs.rawValue < rhs.rawValue
  }

  static func floor(_ tiers: Confidence...) -> Confidence {
    tiers.min() ?? .high
  }
}
