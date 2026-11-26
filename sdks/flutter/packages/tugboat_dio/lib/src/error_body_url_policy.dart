const _star = 0x2a; // '*'
const _question = 0x3f; // '?'
const _hash = 0x23; // '#'

/// One compiled `host[/path]` URL glob.
///
/// The pattern is split at its first `/`. The part before it is the host glob,
/// which is matched against the URL host only, so a `*` there can never span
/// into the path. The rest (starting at `/`) is the path glob, where `*`
/// matches any run of characters. A pattern with no `/` is a bare host glob
/// that matches that whole host with any path. Matching is case-insensitive and
/// anchored, and uses a small iterative matcher (no regular expressions), so
/// its cost is bounded by `O(pattern length * URL length)`.
class UrlGlob {
  UrlGlob._(this._host, this._path);

  final String _host;

  /// `null` for a bare host glob (any path).
  final String? _path;

  /// Whether this glob matches a URL with [host] and [path]. An empty [path]
  /// is treated as `/`.
  bool matches(String host, String path) {
    if (!_globMatches(_host, host.toLowerCase())) return false;
    final pathGlob = _path;
    if (pathGlob == null) return true;
    return _globMatches(pathGlob, (path.isEmpty ? '/' : path).toLowerCase());
  }
}

/// Compiles one `host[/path]` glob, or returns `null` when it is unusable.
///
/// A usable pattern is a host, optionally followed by `/` and a path, where `*`
/// is the only wildcard. Surrounding whitespace is trimmed, runs of `*` collapse
/// to one, and matching ignores case. A pattern is unusable (it could never
/// match, because only the host and path are ever compared) when it:
///
/// * is blank, or starts with `/` (a path with no host),
/// * contains whitespace, a control character or a non-ASCII character,
/// * contains `?` or `#` (query or fragment),
/// * has a host part containing `:` (a scheme or port), `@` (user-info) or
///   `[` / `]` (an IPv6 literal),
/// * has a path part containing a character `Uri.parse` rewrites in paths
///   (`[ ] { } | ^ " < >`, a backtick, or `\`, which becomes `/`). The path of
///   a request is compared in its percent-encoded form, so write `%5B` for
///   `[`; hex digits are matched case-insensitively,
/// * has a path part that the compared path can never contain: a `//` (runs of
///   `/` are collapsed), or a `.` or `..` segment (dot segments are resolved),
///   or an escape of an unreserved character such as `%7E` or `%41` (it is
///   decoded to `~` or `A`; write the character itself),
/// * has a `%` that is not followed by two literal hex digits. A bare `%`
///   becomes `%25` in a request path, and a `*` is not accepted in place of the
///   digits either, so write each escape out in full (`%2F`).
UrlGlob? compileUrlGlob(String pattern) {
  final trimmed = pattern.trim();
  if (trimmed.isEmpty || trimmed.startsWith('/') || _hasBadChar(trimmed)) {
    return null;
  }
  final slash = trimmed.indexOf('/');
  final host = slash < 0 ? trimmed : trimmed.substring(0, slash);
  final path = slash < 0 ? null : trimmed.substring(slash);
  if (_hasBadHostChar(host) || _isUnusablePath(path)) return null;
  return UrlGlob._(_normalize(host), path == null ? null : _normalize(path));
}

String _normalize(String glob) =>
    glob.toLowerCase().replaceAll(RegExp(r'\*+'), '*');

bool _hasBadChar(String pattern) {
  for (final unit in pattern.codeUnits) {
    final isSpaceOrNonAscii = unit <= 0x20 || unit >= 0x7f;
    final isQueryOrFragment = unit == _question || unit == _hash;
    if (isSpaceOrNonAscii || isQueryOrFragment) return true;
  }
  return false;
}

bool _hasBadHostChar(String host) => host.contains(RegExp(r'[:@\[\]]'));

bool _hasBadPathChar(String path) => path.contains(RegExp(r'[\[\]{}|^"<>`\\]'));

/// Whether a path glob (`null` for a bare host pattern) could never match the
/// compared request path, which has `//` collapsed, dot segments resolved and
/// percent-escapes normalised by `Uri.parse`.
bool _isUnusablePath(String? path) =>
    path != null && (_hasBadPathChar(path) || _isNeverNormalForm(path));

bool _isNeverNormalForm(String path) =>
    path.contains('//') ||
    path.split('/').any((segment) => segment == '.' || segment == '..') ||
    path.contains(RegExp('%(?![0-9a-fA-F]{2})')) ||
    RegExp('%([0-9a-fA-F]{2})').allMatches(path).any(_isEscapedUnreserved);

bool _isEscapedUnreserved(RegExpMatch escape) {
  final char = String.fromCharCode(int.parse(escape[1]!, radix: 16));
  return '-._~'.contains(char) || RegExp('[A-Za-z0-9]').hasMatch(char);
}

/// Iterative glob match: `*` matches any run of characters, everything else is
/// literal. Remembers a single backtrack position, so it is `O(glob * text)`
/// in the worst case and never backtracks exponentially.
bool _globMatches(String glob, String text) {
  var g = 0;
  var t = 0;
  var starG = -1;
  var starT = 0;
  while (t < text.length) {
    final unit = g < glob.length ? glob.codeUnitAt(g) : -1;
    if (unit == _star) {
      starG = g++;
      starT = t;
    } else if (unit == text.codeUnitAt(t)) {
      g++;
      t++;
    } else if (starG >= 0) {
      g = starG + 1;
      t = ++starT;
    } else {
      return false;
    }
  }
  return _onlyStarsFrom(glob, g);
}

bool _onlyStarsFrom(String glob, int from) {
  for (var i = from; i < glob.length; i++) {
    if (glob.codeUnitAt(i) != _star) return false;
  }
  return true;
}

/// The only parts of a request URL that error-body URL patterns ever see: the
/// lowercased host and the path (`/` when empty).
typedef UrlHostPath = ({String host, String path});

/// Builds the URL of a request from its Dio [baseUrl] and [path] only.
/// `RequestOptions.queryParameters` are not consulted at all.
///
/// Mirrors how Dio forms the request URL: a [path] starting with `http:` or
/// `https:` is the whole URL, otherwise [baseUrl] and [path] are joined and a
/// doubled `/` at the join is collapsed. Throws [FormatException] when the
/// result is not a parseable URL.
Uri requestUriOf(String baseUrl, String path) {
  var url = path;
  if (!url.startsWith(RegExp(r'https?:'))) {
    url = baseUrl + url;
    final parts = url.split(':/');
    if (parts.length == 2) {
      url = '${parts[0]}:/${parts[1].replaceAll('//', '/')}';
    }
  }
  return Uri.parse(url);
}

/// The host (lowercased) and path of [uri] as error-body URL patterns see
/// them: dot segments resolved like Dio does, runs of `/` collapsed to one, and
/// `/` when empty. The query, fragment, user-info and port are never read.
UrlHostPath hostAndPathOf(Uri uri) {
  final path = uri.normalizePath().path.replaceAll(RegExp('/{2,}'), '/');
  return (host: uri.host.toLowerCase(), path: path.isEmpty ? '/' : path);
}

/// [hostAndPathOf] for the request [baseUrl] + [path]; see [requestUriOf].
UrlHostPath requestHostAndPath(String baseUrl, String path) =>
    hostAndPathOf(requestUriOf(baseUrl, path));

/// Whether an error response body may be retained for [host] and [path].
///
/// A match in [deny] always wins. A `null` [allow] permits every URL; a
/// non-null [allow] permits only matching URLs (an empty list permits none).
bool errorBodyUrlPermitted(
  String host,
  String path, {
  required List<UrlGlob> deny,
  List<UrlGlob>? allow,
}) {
  if (deny.any((glob) => glob.matches(host, path))) return false;
  if (allow == null) return true;
  return allow.any((glob) => glob.matches(host, path));
}

/// Pattern lists for `TugboatDioInterceptor`'s error-body URL controls,
/// compiled once at construction.
///
/// Unusable patterns (see [compileUrlGlob]) never throw at request time, and
/// they trip an `assert` in debug builds that names them. In release builds
/// both lists fail closed: if any deny pattern is unusable, no error body is
/// retained at all, and an allow list left with no usable pattern retains
/// none. (An unusable pattern among usable allow patterns is just skipped.)
class ErrorBodyUrlPolicy {
  ErrorBodyUrlPolicy._(
    this._deny,
    this._allow,
    this._denyAll,
    this.invalidPatterns,
  );

  /// Builds the policy with the debug `assert` on unusable patterns.
  factory ErrorBodyUrlPolicy({
    Iterable<String> deny = const [],
    Iterable<String>? allow,
  }) {
    final policy = ErrorBodyUrlPolicy.lenient(deny: deny, allow: allow);
    assert(
      policy.invalidPatterns.isEmpty,
      'Unusable patterns: ${policy.invalidPatterns}. A pattern is host[/path] '
      'with "*" wildcards and must not: be blank or start with "/"; contain '
      'whitespace, control or non-ASCII characters, "?" or "#"; have ":", "@", '
      '"[" or "]" in the host (no scheme, port, user-info or IPv6 literal); '
      'have [ ] { } | ^ " < > ` or a backslash in the path (use %5B-style '
      'escapes); have "//" or a "." or ".." segment in the path; have a "%" '
      'not followed by two literal hex digits; or escape an unreserved '
      'character such as %7E or %41 (write it plainly). In release builds an '
      'unusable errorBodyDenyUrls entry drops every error body.',
    );
    return policy;
  }

  /// Builds the policy without the debug `assert`: exactly what a release
  /// build does with unusable patterns.
  factory ErrorBodyUrlPolicy.lenient({
    Iterable<String> deny = const [],
    Iterable<String>? allow,
  }) {
    final invalidDeny = <String>[];
    final invalidAllow = <String>[];
    final compiledDeny = _compileAll(deny, invalidDeny);
    final compiledAllow = allow == null
        ? null
        : _compileAll(allow, invalidAllow);
    return ErrorBodyUrlPolicy._(
      compiledDeny,
      compiledAllow,
      invalidDeny.isNotEmpty,
      List.unmodifiable([...invalidDeny, ...invalidAllow]),
    );
  }

  final List<UrlGlob> _deny;
  final List<UrlGlob>? _allow;
  final bool _denyAll;

  /// Patterns that were not accepted and were ignored (or, for deny, made the
  /// policy drop every body).
  final List<String> invalidPatterns;

  /// True when no list restricts anything (today's retain-everything default).
  bool get isUnrestricted => !_denyAll && _allow == null && _deny.isEmpty;

  /// Whether a body may be retained for the request [baseUrl] + [path] and
  /// for every hop of its [redirects] (the `location` of each redirect record,
  /// in order). Each location may be relative to the hop before it, so the
  /// chain is resolved hop by hop starting from the request URL. Any URL
  /// matching a deny pattern drops the body, and an allow list must allow
  /// every URL. Only host and path are read. Throws [FormatException] for an
  /// unparseable URL.
  bool permits(String baseUrl, String path, {List<Uri> redirects = const []}) {
    if (_denyAll) return false;
    var current = requestUriOf(baseUrl, path);
    if (!_permitsUri(current)) return false;
    for (final location in redirects) {
      current = current.resolveUri(location);
      if (!_permitsUri(current)) return false;
    }
    return true;
  }

  bool _permitsUri(Uri uri) {
    final subject = hostAndPathOf(uri);
    return errorBodyUrlPermitted(
      subject.host,
      subject.path,
      deny: _deny,
      allow: _allow,
    );
  }

  static List<UrlGlob> _compileAll(
    Iterable<String> patterns,
    List<String> invalid,
  ) {
    final compiled = <UrlGlob>[];
    for (final pattern in patterns) {
      final glob = compileUrlGlob(pattern);
      if (glob == null) {
        invalid.add(pattern);
      } else {
        compiled.add(glob);
      }
    }
    return compiled;
  }
}
