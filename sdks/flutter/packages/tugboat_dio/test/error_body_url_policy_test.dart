import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tugboat_dio/src/error_body_url_policy.dart';

UrlGlob _glob(String pattern) => compileUrlGlob(pattern)!;

bool _matches(String pattern, String url) {
  final subject = requestHostAndPath('', url);
  return _glob(pattern).matches(subject.host, subject.path);
}

void main() {
  group('UrlGlob path matching', () {
    test('star in the path matches any run, including slashes', () {
      final glob = _glob('api.example.com/v1/*');
      expect(glob.matches('api.example.com', '/v1/'), isTrue);
      expect(glob.matches('api.example.com', '/v1/accounts/42'), isTrue);
      expect(glob.matches('api.example.com', '/v2/accounts'), isFalse);
    });

    test('the collection URL needs its own pattern', () {
      final glob = _glob('api.example.com/v1/accounts/*');
      expect(glob.matches('api.example.com', '/v1/accounts/42'), isTrue);
      expect(glob.matches('api.example.com', '/v1/accounts'), isFalse);
      expect(
        _glob(
          'api.example.com/v1/accounts',
        ).matches('api.example.com', '/v1/accounts'),
        isTrue,
      );
    });

    test('is anchored on the whole host and path', () {
      final glob = _glob('example.com/login');
      expect(glob.matches('example.com', '/login'), isTrue);
      expect(glob.matches('example.com', '/login/extra'), isFalse);
      expect(glob.matches('api.example.com', '/login'), isFalse);
    });

    test('is case-insensitive', () {
      final glob = _glob('API.Example.COM/Users/*');
      expect(glob.matches('api.example.com', '/users/7'), isTrue);
      expect(glob.matches('API.EXAMPLE.COM', '/USERS/7'), isTrue);
    });

    test('regular-expression characters are literal', () {
      // `[` and `]` are percent-encoded in a request path, so the pattern
      // uses the encoded form; the URL goes through requestHostAndPath.
      const pattern = 'a.example.com/v(1)+/%5Bx%5D';
      expect(_matches(pattern, 'https://a.example.com/v(1)+/[x]'), isTrue);
      expect(_matches(pattern, 'https://aXexample.com/v(1)+/[x]'), isFalse);
      expect(_matches(pattern, 'https://a.example.com/v1/x'), isFalse);
    });

    test('an empty URL path is treated as /', () {
      final glob = _glob('api.example.com/*');
      expect(glob.matches('api.example.com', ''), isTrue);
      expect(_matches('api.example.com/*', 'https://api.example.com'), isTrue);
      expect(_glob('api.example.com/').matches('api.example.com', ''), isTrue);
      expect(
        _glob('api.example.com/').matches('api.example.com', '/x'),
        isFalse,
      );
    });

    test('interior and trailing stars', () {
      final inner = _glob('api.example.com/*/reset');
      expect(inner.matches('api.example.com', '/users/reset'), isTrue);
      expect(inner.matches('api.example.com', '/reset'), isFalse);
      expect(_glob('a.test/x*').matches('a.test', '/x'), isTrue);
    });

    test('trims surrounding whitespace', () {
      expect(_glob('  example.com/x  ').matches('example.com', '/x'), isTrue);
    });
  });

  group('UrlGlob host matching', () {
    test('a bare host pattern matches that whole host with any path', () {
      final glob = _glob('api.example.com');
      expect(glob.matches('api.example.com', ''), isTrue);
      expect(glob.matches('api.example.com', '/'), isTrue);
      expect(glob.matches('api.example.com', '/any/path/at/all'), isTrue);
      expect(glob.matches('api.example.com.evil.test', '/x'), isFalse);
      expect(glob.matches('other.example.com', '/x'), isFalse);
    });

    test('star in the host cannot reach into the path', () {
      expect(
        _matches('*.example.com/*', 'https://other.test/x/api.example.com/y'),
        isFalse,
      );
      expect(_matches('*.example.com/*', 'https://api.example.com/y'), isTrue);
      expect(
        _matches('*example.com*', 'https://other.test/example.com'),
        isFalse,
      );
    });

    test('a star in the host is a real wildcard, so anchor with the dot', () {
      expect(
        _glob('api.example.com*').matches('api.example.com.x.test', '/'),
        isTrue,
      );
      expect(_glob('*.example.com').matches('example.com', '/'), isFalse);
      expect(_glob('*.example.com').matches('a.b.example.com', '/'), isTrue);
    });
  });

  group('compileUrlGlob rejects patterns that can never match', () {
    for (final bad in <String>[
      '',
      '   ',
      '/v1/accounts/*',
      'example.com:8443/x',
      'example.com:8443',
      'https://example.com/x',
      'user:pw@example.com/x',
      'user@example.com/x',
      '[::1]/x',
      'example.com/x?email=*',
      'example.com/x#frag',
      'example.com/a b',
      'example.com/é',
      'exämple.com/x',
      'example.com/x\ty',
      'example.com/a[1]',
      'example.com/a]',
      'example.com/a{b}',
      'example.com/a|b',
      'example.com/a^b',
      'example.com/a"b',
      'example.com/a<b>',
      'example.com/a`b',
      r'example.com/a\b',
      'api.example.com//v1/accounts/*',
      'api.example.com/v1//accounts',
      'api.example.com/v1/../admin/*',
      'api.example.com/v1/./accounts',
      'api.example.com/..',
      'api.example.com/%7Euser/*',
      'api.example.com/a%7eb',
      'api.example.com/a%41',
      'api.example.com/a%2D',
      'api.example.com/a%2e',
      'api.example.com/50%',
      'api.example.com/a%zz',
      'api.example.com/a%4',
      'api.example.com/a%*',
      'api.example.com/a%2*',
    ]) {
      test(
        'rejects ${bad.isEmpty ? '<empty>' : bad.replaceAll('\t', r'\t')}',
        () {
          expect(compileUrlGlob(bad), isNull);
        },
      );
    }

    test('look-alike patterns that are usable stay usable', () {
      expect(compileUrlGlob('api.example.com/v1/..x/*'), isNotNull);
      expect(compileUrlGlob('api.example.com/a.b/c..d'), isNotNull);
      expect(compileUrlGlob('api.example.com/a%2Fb'), isNotNull);
      expect(compileUrlGlob('api.example.com/a%20b'), isNotNull);
      expect(compileUrlGlob('api.example.com/*/%5B1%5D'), isNotNull);
    });

    test('percent-encoded path characters match case-insensitively', () {
      final glob = _glob('example.com/a%5Bb%5D');
      expect(glob.matches('example.com', '/a%5bb%5d'), isTrue);
      expect(
        _matches('example.com/a%5bb%5d', 'https://example.com/a[b]'),
        isTrue,
      );
    });

    test('colon and at-sign in the path are allowed', () {
      expect(
        _glob(
          'example.com/v1/users:search',
        ).matches('example.com', '/v1/users:search'),
        isTrue,
      );
      expect(_glob('example.com/@me').matches('example.com', '/@me'), isTrue);
    });
  });

  group('matcher cost', () {
    final longUrl = 'a' * 250;

    test('many adjacent stars with a literal tail stay fast', () {
      final glob = _glob('${'*' * 20}x');
      final watch = Stopwatch()..start();
      expect(glob.matches('example.com', '/$longUrl'), isFalse);
      expect(
        _glob('${'*' * 20}.example.com/x').matches('e.test', '/$longUrl'),
        isFalse,
      );
      watch.stop();
      expect(watch.elapsedMilliseconds, lessThan(1000));
    });

    test('repeated star-slash groups stay fast', () {
      final glob = _glob('**/**/**/**/**/x');
      final watch = Stopwatch()..start();
      expect(glob.matches('example.com', '/${'a/' * 120}y'), isFalse);
      expect(
        _glob(
          'example.com/**/**/**/**/**/x',
        ).matches('example.com', '/${'a/' * 120}y'),
        isFalse,
      );
      watch.stop();
      expect(watch.elapsedMilliseconds, lessThan(1000));
    });
  });

  group('requestHostAndPath', () {
    test('joins baseUrl and path like Dio and keeps only host and path', () {
      final subject = requestHostAndPath(
        'https://user:pw@Api.Example.com:8443/api',
        '/v1/a?email=a@b.com#frag',
      );
      expect(subject, (host: 'api.example.com', path: '/api/v1/a'));
    });

    test('an absolute path replaces the baseUrl', () {
      final subject = requestHostAndPath(
        'https://base.test/api',
        'https://other.test/v2/x?y=1',
      );
      expect(subject, (host: 'other.test', path: '/v2/x'));
    });

    test('collapses a doubled slash at the join', () {
      final subject = requestHostAndPath('https://a.test/', '/x');
      expect(subject, (host: 'a.test', path: '/x'));
    });

    test('no path yields /', () {
      expect(requestHostAndPath('https://a.test', ''), (
        host: 'a.test',
        path: '/',
      ));
    });

    test('throws FormatException for an unparseable URL', () {
      expect(
        () => requestHostAndPath('http://[bad', '/x'),
        throwsFormatException,
      );
    });
  });

  group('errorBodyUrlPermitted', () {
    const host = 'api.example.com';
    const path = '/v1/accounts/42';

    test('no lists permits every URL', () {
      expect(errorBodyUrlPermitted(host, path, deny: const []), isTrue);
    });

    test('deny blocks a matching URL and leaves others', () {
      final deny = [_glob('api.example.com/v1/accounts/*')];
      expect(errorBodyUrlPermitted(host, path, deny: deny), isFalse);
      expect(errorBodyUrlPermitted(host, '/v1/health', deny: deny), isTrue);
    });

    test('allow permits only matching URLs', () {
      final allow = [_glob('api.example.com/v1/health')];
      expect(
        errorBodyUrlPermitted(host, path, deny: const [], allow: allow),
        isFalse,
      );
      expect(
        errorBodyUrlPermitted(host, '/v1/health', deny: const [], allow: allow),
        isTrue,
      );
    });

    test('an empty allow list permits nothing', () {
      expect(
        errorBodyUrlPermitted(host, path, deny: const [], allow: []),
        isFalse,
      );
    });

    test('deny beats allow', () {
      expect(
        errorBodyUrlPermitted(
          host,
          path,
          deny: [_glob('*/v1/accounts/*')],
          allow: [_glob('api.example.com/*')],
        ),
        isFalse,
      );
    });
  });

  group('ErrorBodyUrlPolicy', () {
    test('default is unrestricted and permits everything', () {
      final policy = ErrorBodyUrlPolicy();
      expect(policy.isUnrestricted, isTrue);
      expect(policy.permits('https://example.com', '/a'), isTrue);
    });

    test('never reads the query when deciding', () {
      final policy = ErrorBodyUrlPolicy(
        deny: ['*/admin*'],
        allow: ['example.com/*'],
      );
      expect(policy.isUnrestricted, isFalse);
      expect(
        policy.permits('https://example.com', '/a?next=/admin#admin'),
        isTrue,
      );
      expect(policy.permits('https://example.com', '/admin'), isFalse);
    });

    test('unusable patterns trip an assert in debug builds', () {
      for (final bad in ['example.com/x?q=*', '', ':8080', '/x']) {
        expect(
          () => ErrorBodyUrlPolicy(deny: [bad]),
          throwsA(isA<AssertionError>()),
        );
        expect(
          () => ErrorBodyUrlPolicy(allow: [bad]),
          throwsA(isA<AssertionError>()),
        );
      }
    });

    test('the debug assert names the unusable pattern', () {
      const typo = 'https://api.example.com/v1/accounts/*';
      expect(
        () => ErrorBodyUrlPolicy(deny: [typo]),
        throwsA(
          isA<AssertionError>().having(
            (e) => e.message.toString(),
            'message',
            contains(typo),
          ),
        ),
      );
    });

    // `lenient` is what a release build does: no assert.
    group('release behaviour for unusable patterns', () {
      const goodDeny = 'api.example.com/v1/accounts/*';
      const typo = 'https://api.example.com/v1/accounts/*';
      final other = Uri.parse('https://api.example.com/v1/health');

      bool permitsAny(ErrorBodyUrlPolicy policy) =>
          policy.permits('', other.toString());

      test('one bad deny pattern among good ones drops every body', () {
        final policy = ErrorBodyUrlPolicy.lenient(deny: [goodDeny, typo]);
        expect(policy.isUnrestricted, isFalse);
        expect(policy.invalidPatterns, [typo]);
        expect(permitsAny(policy), isFalse);
        expect(policy.permits('', 'https://elsewhere.test/x'), isFalse);
      });

      test('a deny list of only bad patterns drops every body', () {
        final policy = ErrorBodyUrlPolicy.lenient(deny: [typo, '']);
        expect(policy.isUnrestricted, isFalse);
        expect(permitsAny(policy), isFalse);
      });

      test('deny-all does not parse the URL, so it cannot throw', () {
        final policy = ErrorBodyUrlPolicy.lenient(deny: [typo]);
        expect(policy.permits('http://[bad', '/x'), isFalse);
      });

      test('a bad allow pattern among good ones is skipped', () {
        final policy = ErrorBodyUrlPolicy.lenient(
          allow: ['api.example.com/*', typo],
        );
        expect(policy.invalidPatterns, [typo]);
        expect(permitsAny(policy), isTrue);
        expect(policy.permits('', 'https://elsewhere.test/x'), isFalse);
      });

      test('an allow list of only bad patterns keeps no body', () {
        final policy = ErrorBodyUrlPolicy.lenient(allow: [typo]);
        expect(permitsAny(policy), isFalse);
      });

      test('valid patterns leave nothing invalid', () {
        final policy = ErrorBodyUrlPolicy.lenient(
          deny: [goodDeny],
          allow: ['api.example.com'],
        );
        expect(policy.invalidPatterns, isEmpty);
      });
    });
  });

  group('subject path normalisation', () {
    test('runs of slashes collapse before matching', () {
      expect(
        requestHostAndPath('https://a.test', '//v1///accounts//42').path,
        '/v1/accounts/42',
      );
      expect(
        _matches('a.test/v1/accounts/*', 'https://a.test//v1//accounts/42'),
        isTrue,
      );
      expect(requestHostAndPath('https://a.test', '///').path, '/');
    });

    test('dot segments are resolved like Dio does', () {
      expect(
        _matches('a.test/v1/accounts/*', 'https://a.test/v1/x/../accounts/4'),
        isTrue,
      );
      expect(
        _matches('a.test/v1/accounts/*', 'https://a.test/v1/./accounts/4'),
        isTrue,
      );
    });
  });

  group('requestHostAndPath agrees with Dio RequestOptions.uri', () {
    const cases = <(String, String)>[
      ('https://api.example.com', '/v1/a'),
      ('https://api.example.com/', '/v1/a'),
      ('https://api.example.com/', 'v1/a'),
      ('https://api.example.com', 'v1/a'),
      ('https://api.example.com/api', '/v1/a'),
      ('https://api.example.com/api/', '/v1/a'),
      ('https://api.example.com/api/', 'v1/a'),
      ('https://api.example.com', ''),
      ('https://api.example.com/', ''),
      ('https://api.example.com', '/'),
      ('https://base.test/api', 'https://other.test/v2/x'),
      ('https://base.test/api', 'http://other.test'),
      ('', 'https://other.test/v2/x'),
      ('https://api.example.com', '/v1/a?email=a@b.com&x=/y#frag'),
      ('https://api.example.com/api?z=1', '/v1/a'),
      ('https://user:pw@api.example.com:8443/api', '/v1/a'),
      ('https://API.Example.COM', '/V1/A'),
      ('http://[::1]:8080', '/x'),
      ('http://[2001:db8::1]/api', '/x/y'),
      ('https://a.test', '//v1//a'),
      ('https://a.test//', '//v1/a'),
      ('https://a.test/a', '/../b'),
      ('https://a.test', '/x/./y/../z'),
      ('https://a.test', '/a[1]/{b}|c'),
    ];
    for (final (baseUrl, path) in cases) {
      test('baseUrl "$baseUrl" + path "$path"', () {
        final dio = RequestOptions(baseUrl: baseUrl, path: path).uri;
        final expectedPath = dio.path.replaceAll(RegExp('/{2,}'), '/');
        final ours = requestHostAndPath(baseUrl, path);
        expect(ours.host, dio.host.toLowerCase());
        expect(ours.path, expectedPath.isEmpty ? '/' : expectedPath);
      });
    }

    test('queryParameters change Dio\'s uri but never ours', () {
      final options = RequestOptions(
        baseUrl: 'https://a.test',
        path: '/v1/a',
        queryParameters: {'next': '/admin', 'email': 'a@b.com'},
      );
      final ours = requestHostAndPath(options.baseUrl, options.path);
      expect(ours, (host: 'a.test', path: '/v1/a'));
      expect(options.uri.path, '/v1/a');
    });
  });

  group('redirect chains', () {
    final denySso = ErrorBodyUrlPolicy(deny: ['sso.example.com']);
    final allowApi = ErrorBodyUrlPolicy(allow: ['api.example.com/*']);

    bool permits(ErrorBodyUrlPolicy policy, String start, List<String> hops) =>
        policy.permits('', start, redirects: hops.map(Uri.parse).toList());

    test('a denied final URL drops the body', () {
      final policy = ErrorBodyUrlPolicy(deny: ['evil.test/*']);
      expect(
        permits(policy, 'https://api.example.com/x', [
          'https://evil.test/landing?x=1',
        ]),
        isFalse,
      );
      expect(
        permits(policy, 'https://api.example.com/x', [
          'https://ok.test/landing',
        ]),
        isTrue,
      );
    });

    test('a two-hop chain with a relative last Location uses the hop host', () {
      // api -> sso -> "/error" on sso: the last URL is sso.example.com/error.
      expect(
        permits(denySso, 'https://api.example.com/start', [
          'https://sso.example.com/login',
          '/error',
        ]),
        isFalse,
      );
    });

    test('a relative first hop resolves against the request URL', () {
      final policy = ErrorBodyUrlPolicy(deny: ['api.example.com/a/sub/*']);
      expect(
        permits(policy, 'https://api.example.com/a/b', ['sub/x', 'y']),
        isFalse,
      );
      expect(
        permits(policy, 'https://api.example.com/a/b', ['other/x', 'y']),
        isTrue,
      );
    });

    test('a denied intermediate hop drops the body', () {
      final policy = ErrorBodyUrlPolicy(deny: ['evil.test']);
      expect(
        permits(policy, 'https://api.example.com/x', [
          'https://evil.test/hop',
          'https://api.example.com/back',
        ]),
        isFalse,
      );
    });

    test('an allow list needs every hop allowed', () {
      expect(
        permits(allowApi, 'https://api.example.com/x', [
          '/y',
          'https://api.example.com/z',
        ]),
        isTrue,
      );
      expect(
        permits(allowApi, 'https://api.example.com/x', [
          'https://other.test/hop',
          'https://api.example.com/back',
        ]),
        isFalse,
      );
    });

    // Each hop must be resolved against the hop BEFORE it. Every test below
    // gives a different answer if hops were resolved against the request URL.
    test('(a) deny on the second hop path, resolved against hop one', () {
      // Right: sso.example.com/error (denied). Against the request URL it
      // would be api.example.com/error, which is not denied.
      final policy = ErrorBodyUrlPolicy(deny: ['sso.example.com/error']);
      expect(
        permits(policy, 'https://api.example.com/start', [
          'https://sso.example.com/login',
          '/error',
        ]),
        isFalse,
      );
    });

    test('(b) allow list rejects a second hop resolved against hop one', () {
      // Right: sso.example.com/error is not allowed. Against the request URL
      // it would be api.example.com/error, which the first pattern allows.
      final policy = ErrorBodyUrlPolicy(
        allow: ['api.example.com/*', 'sso.example.com/login'],
      );
      expect(
        permits(policy, 'https://api.example.com/start', [
          'https://sso.example.com/login',
          '/error',
        ]),
        isFalse,
      );
    });

    test(
      '(c) a relative first hop is allowed only via the request directory',
      () {
        // Right: /a/b/c + "d" = /a/b/d (allowed). Against the host root it
        // would be /d, which is outside the allow list.
        final policy = ErrorBodyUrlPolicy(allow: ['api.example.com/a/b/*']);
        expect(permits(policy, 'https://api.example.com/a/b/c', ['d']), isTrue);
      },
    );

    test('(c) a second relative hop is denied only via the previous hop', () {
      // Right: hop one /a/x/one, hop two /a/x/two (denied). Against the
      // request URL /a/b it would be /a/two, which is not denied.
      final policy = ErrorBodyUrlPolicy(deny: ['api.example.com/a/x/two']);
      expect(
        permits(policy, 'https://api.example.com/a/b', ['x/one', 'two']),
        isFalse,
      );
    });

    test('(c) a second relative hop is allowed only via the previous hop', () {
      // Right: /a/x/two (allowed). Against the request URL it would be
      // /a/two, which is outside the allow list.
      final policy = ErrorBodyUrlPolicy(
        allow: ['api.example.com/a/b', 'api.example.com/a/x/*'],
      );
      expect(
        permits(policy, 'https://api.example.com/a/b', ['x/one', 'two']),
        isTrue,
      );
    });

    test('no redirects checks only the request URL', () {
      expect(denySso.permits('', 'https://api.example.com/x'), isTrue);
    });
  });

  group('README examples', () {
    // Keep in sync with the example in README.md.
    final readme = ErrorBodyUrlPolicy(
      deny: [
        'api.example.com/v1/accounts',
        'api.example.com/v1/accounts/*',
        '*/*password*',
      ],
      allow: ['api.example.com'],
    );

    bool permits(String url) => readme.permits('', url);

    test('denied URLs lose their body', () {
      expect(permits('https://api.example.com/v1/accounts'), isFalse);
      expect(permits('https://api.example.com/v1/accounts/42'), isFalse);
      expect(permits('https://api.example.com/v1/password/reset'), isFalse);
      expect(
        permits('https://api.example.com/v1/auth/Password-Reset'),
        isFalse,
      );
    });

    test('other URLs on the allowed host keep it', () {
      expect(permits('https://api.example.com/v1/health'), isTrue);
      expect(permits('https://api.example.com'), isTrue);
      expect(permits('https://api.example.com:8443/v1/orders/9?x=1'), isTrue);
    });

    test('other hosts are outside the allow list', () {
      expect(permits('https://other.example.com/v1/health'), isFalse);
    });
  });
}
