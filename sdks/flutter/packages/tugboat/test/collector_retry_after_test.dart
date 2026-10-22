import 'package:flutter_test/flutter_test.dart';
import 'package:tugboat/src/collector_retry_after.dart';

void main() {
  final now = DateTime.utc(2026, 6, 19);

  test('delta seconds', () {
    expect(parseCollectorRetryAfterDelayMs('5', now), 5000);
    expect(parseCollectorRetryAfterDelayMs('120', now), 60000);
    expect(parseCollectorRetryAfterDelayMs('not-a-date', now), isNull);
  });

  test('http-date in the past yields zero', () {
    expect(
      parseCollectorRetryAfterDelayMs('Sun, 06 Nov 1994 08:49:37 GMT', now),
      0,
    );
  });

  test('http-date in the future', () {
    final future = now.add(const Duration(seconds: 10));
    expect(parseCollectorRetryAfterDelayMs('3', future), 3000);
  });
}
