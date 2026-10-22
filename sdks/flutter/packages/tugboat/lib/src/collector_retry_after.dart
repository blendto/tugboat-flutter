/// Parses collector `Retry-After` response headers for [CollectorHttpSink].
library;

const collectorMaxRetryAfterMs = 60000;
const collectorMaxEndingRetryAfterMs = 10000;
const collectorMaxRetryAfterHeaderBytes = 128;

/// Delay before retrying, in milliseconds, capped at [capMs]. Returns null when
/// the header is missing or unparseable.
int? parseCollectorRetryAfterDelayMs(
  String? raw,
  DateTime now, {
  int capMs = collectorMaxRetryAfterMs,
}) {
  if (raw == null) return null;
  final value = raw.trim();
  if (value.isEmpty || value.length > collectorMaxRetryAfterHeaderBytes) {
    return null;
  }
  if (_deltaSecondsPattern.hasMatch(value)) {
    return _parseDeltaSecondsMs(value, capMs);
  }
  final date = _parseImfFixDate(value);
  if (date == null) return null;
  final delay = date.difference(now).inMilliseconds;
  if (delay <= 0) return 0;
  return delay > capMs ? capMs : delay;
}

int? _parseDeltaSecondsMs(String value, int capMs) {
  final seconds = BigInt.tryParse(value);
  if (seconds == null) return null;
  final capSeconds = BigInt.from(capMs) ~/ BigInt.from(1000);
  if (seconds > capSeconds) return capMs;
  final ms = seconds * BigInt.from(1000);
  if (ms > BigInt.from(capMs)) return capMs;
  return ms.toInt();
}

final _deltaSecondsPattern = RegExp(r'^[0-9]+$');

const _weekdays = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'];

/// IMF-fixdate (`Sun, 06 Nov 1994 08:49:37 GMT`), UTC.
DateTime? _parseImfFixDate(String value) {
  if (value.length != 29 ||
      !value.endsWith(' GMT') ||
      value[3] != ',' ||
      value[4] != ' ' ||
      value[7] != ' ' ||
      value[11] != ' ' ||
      value[16] != ' ' ||
      value[19] != ':' ||
      value[22] != ':') {
    return null;
  }
  if (!_weekdays.any((day) => value.startsWith(day))) {
    return null;
  }
  if (!_isTwoDigits(value, 5) ||
      !_isTwoDigits(value, 12) ||
      !_isTwoDigits(value, 17) ||
      !_isTwoDigits(value, 20) ||
      !_isTwoDigits(value, 23)) {
    return null;
  }
  final day = int.parse(value.substring(5, 7));
  final month = _monthIndex(value.substring(8, 11));
  final year = int.parse(value.substring(12, 16));
  final hour = int.parse(value.substring(17, 19));
  final minute = int.parse(value.substring(20, 22));
  var second = int.parse(value.substring(23, 25));
  if (month == null ||
      !_civilDateValid(year, month, day) ||
      hour > 23 ||
      minute > 59 ||
      second > 60) {
    return null;
  }
  if (second == 60) {
    second = 59;
  }
  return DateTime.utc(year, month, day, hour, minute, second);
}

bool _isTwoDigits(String value, int start) {
  final a = value.codeUnitAt(start);
  final b = value.codeUnitAt(start + 1);
  return a >= 0x30 && a <= 0x39 && b >= 0x30 && b <= 0x39;
}

bool _civilDateValid(int year, int month, int day) {
  if (month < 1 || month > 12 || day < 1) return false;
  const days = [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31];
  var maxDay = days[month - 1];
  if (month == 2) {
    final leap = (year % 4 == 0 && year % 100 != 0) || year % 400 == 0;
    maxDay = leap ? 29 : 28;
  }
  return day <= maxDay;
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
