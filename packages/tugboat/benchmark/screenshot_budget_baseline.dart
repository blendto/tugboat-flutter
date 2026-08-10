/// Screenshot budget baseline fixture (U5/U7).
///
/// Thresholds are intentionally conservative defaults used by unit tests.
/// Device-tier release measurements should update these numbers before
/// enabling aggressive degradation in production profiles.
class ScreenshotBudgetBaseline {
  static const window = Duration(seconds: 5);
  static const budgetMicros = 60 * 1000;
  static const maxAvgEncodeMicros = 50 * 1000;
  static const maxAvgReadbackMicros = 40 * 1000;
}
