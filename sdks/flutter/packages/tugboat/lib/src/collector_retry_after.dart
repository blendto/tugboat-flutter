/// Parses collector `Retry-After` response headers for [CollectorHttpSink].
library;

const collectorMaxRetryAfterMs = 60000;
const collectorMaxRetryAfterHeaderBytes = 128;

/// Delay before retrying, in milliseconds, capped at [capMs]. Returns null when
/// the header is missing or unparseable.
int? parseCollectorRetryAfterDelayMs(
  String? raw,
  DateTime now, {
  int capMs = collectorMaxRetryAfterMs,
}) {
  if (raw == null) return null;
  var value = raw.trim();
  if (value.isEmpty || value.length > collectorMaxRetryAfterHeaderBytes) {
    return null;
  }
  if (_deltaSecondsPattern.hasMatch(value)) {
    final seconds = int.tryParse(value);
    if (seconds == null) return null;
    final ms = seconds * 1000;
    return ms > capMs ? capMs : ms;
  }
  final date = _parseImfFixDate(value);
  if (date == null) return null;
  final delay = date.difference(now).inMilliseconds;
  if (delay <= 0) return 0;
  return delay > capMs ? capMs : delay;
}

final _deltaSecondsPattern = RegExp(r'^[0-9]+$');

/// IMF-fixdate (`Sun, 06 Nov 1994 08:49:37 GMT`), UTC.
DateTime? _parseImfFixDate(String value) {
  if (value.length < 29 ||
      !value.endsWith(' GMT') ||
      value[3] != ',' ||
      value[4] != ' ') {
    return null;
  }
  final day = int.tryParse(value.substring(5, 7));
  final month = _monthIndex(value.substring(8, 11));
  final year = int.tryParse(value.substring(12, 16));
  final hour = int.tryParse(value.substring(17, 19));
  final minute = int.tryParse(value.substring(20, 22));
  final second = int.tryParse(value.substring(23, 25));
  if (day == null ||
      month == null ||
      year == null ||
      hour == null ||
      minute == null ||
      second == null) {
    return null;
  }
  return DateTime.utc(year, month, day, hour, minute, second);
}

int? _monthIndex(String mon) {
  const months = [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];
  for (var i = 0; i < months.length; i++) {
    if (mon == months[i]) return i + 1;
  }
  return null;
}
