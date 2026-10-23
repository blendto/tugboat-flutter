/// Parses collector `Retry-After` response headers for [CollectorHttpSink].
library;

/// Longest header value considered, in bytes after the trim (the engine's
/// `kMaxRetryAfterHeaderBytes`). Longer values are ignored.
const collectorMaxRetryAfterHeaderBytes = 128;

/// Delay before retrying, in milliseconds, capped at [capMs]. Returns null when
/// the header is missing or unparseable.
///
/// Trims ASCII whitespace only, as the engine does; a value that is empty or
/// longer than [collectorMaxRetryAfterHeaderBytes] after the trim is ignored.
/// A date relative to [now] (wall clock) in the past is zero.
int? parseCollectorRetryAfterDelayMs(
  String? raw,
  DateTime now, {
  required int capMs,
}) {
  if (raw == null) return null;
  final value = _trimAsciiWhitespace(raw);
  // Non-ASCII values never parse, so UTF-16 length stands in for bytes.
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

/// C `isspace` in the C locale: space, tab, LF, VT, FF, CR.
bool _isAsciiWhitespace(int codeUnit) =>
    codeUnit == 0x20 || (codeUnit >= 0x09 && codeUnit <= 0x0d);

String _trimAsciiWhitespace(String raw) {
  var start = 0;
  var end = raw.length;
  while (start < end && _isAsciiWhitespace(raw.codeUnitAt(start))) {
    start++;
  }
  while (end > start && _isAsciiWhitespace(raw.codeUnitAt(end - 1))) {
    end--;
  }
  return raw.substring(start, end);
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
  if (!_hasImfFixDateShape(value)) return null;
  final day = _twoDigitValue(value, 5);
  final month = _monthIndex(value.substring(8, 11));
  final year = _fourDigitValue(value, 12);
  final hour = _twoDigitValue(value, 17);
  final minute = _twoDigitValue(value, 20);
  final second = _twoDigitValue(value, 23);
  if (month == null ||
      !_civilDateValid(year, month, day) ||
      !_clockValid(hour, minute, second)) {
    return null;
  }
  // A leap second reads as the second before it.
  return DateTime.utc(
    year,
    month,
    day,
    hour,
    minute,
    second == 60 ? 59 : second,
  );
}

/// Fixed separators of an IMF-fixdate, by offset.
const _imfSeparators = {
  3: ',',
  4: ' ',
  7: ' ',
  11: ' ',
  16: ' ',
  19: ':',
  22: ':',
};

/// Offsets of the two-digit day, hour, minute, and second fields.
const _imfTwoDigitFields = [5, 17, 20, 23];

/// Length, separators, weekday, `GMT`, and that every numeric field is
/// digits (checked before any value is computed).
bool _hasImfFixDateShape(String value) {
  if (value.length != 29 || !value.endsWith(' GMT')) return false;
  for (final separator in _imfSeparators.entries) {
    if (value[separator.key] != separator.value) return false;
  }
  if (!_weekdays.any(value.startsWith)) return false;
  return _isFourDigits(value, 12) &&
      _imfTwoDigitFields.every((start) => _isTwoDigits(value, start));
}

bool _clockValid(int hour, int minute, int second) =>
    hour <= 23 && minute <= 59 && second <= 60;

bool _isTwoDigits(String value, int start) {
  final a = value.codeUnitAt(start);
  final b = value.codeUnitAt(start + 1);
  return a >= 0x30 && a <= 0x39 && b >= 0x30 && b <= 0x39;
}

bool _isFourDigits(String value, int start) {
  return _isTwoDigits(value, start) && _isTwoDigits(value, start + 2);
}

int _twoDigitValue(String value, int start) =>
    (value.codeUnitAt(start) - 0x30) * 10 +
    (value.codeUnitAt(start + 1) - 0x30);

int _fourDigitValue(String value, int start) =>
    _twoDigitValue(value, start) * 100 + _twoDigitValue(value, start + 2);

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
