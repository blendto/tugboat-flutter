import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tugboat/src/anchors.dart';
import 'package:tugboat/tugboat.dart';

/// Guards fingerprint identity. Any change to a fixture's fingerprints, route
/// keys or aliases fails here: bump [tugboatFingerprintSchemaVersion] and
/// update the golden below in the same change.
const _goldenSchemaVersion = 7;

/// Observed schema 7 output of [_goldenTree] under the named route `/golden`
/// and under an anonymous route.
final Map<String, Object?> _goldenExpected = {
  'named': {
    'routeKey': '/golden',
    'entries': [
      {
        'fingerprint': 'b81b3e59183ebd21',
        'tier': 'interactive',
        'role': 'button',
        'enabled': true,
        'aliases': ['25b1b03b6a41028f', '6da905874663e646'],
        'tag': null,
      },
      {
        'fingerprint': '19bfc5f7961a3550',
        'tier': 'interactive',
        'role': 'button',
        'enabled': false,
        'aliases': ['38e6eda60d89e91b'],
        'tag': null,
      },
      {
        'fingerprint': 'd3b6f52768a94fd4',
        'tier': 'interactive',
        'role': 'button',
        'enabled': true,
        'aliases': ['1e0730bd5f6bec07', '655f0d398ae48748'],
        'tag': null,
      },
      {
        'fingerprint': 'e72ca8effba2e941',
        'tier': 'interactive',
        'role': 'button',
        'enabled': true,
        'aliases': ['5cbc415df9f25d9f', '68a14595e303625e'],
        'tag': null,
      },
      {
        'fingerprint': 'c87181fabf34189d',
        'tier': 'interactive',
        'role': 'button',
        'enabled': true,
        'aliases': [],
        'tag': null,
      },
      {
        'fingerprint': '8b3fde97c2246047',
        'tier': 'interactive',
        'role': 'button',
        'enabled': true,
        'aliases': ['b3e2cd635f763dc3', 'f22b6e97553c1759'],
        'tag': 'cta',
      },
    ],
  },
  'anonymous': {
    'routeKey': 'struct:33ab873812401058',
    'entries': [
      {
        'fingerprint': 'a7d352389ddc0531',
        'tier': 'interactive',
        'role': 'button',
        'enabled': true,
        'aliases': [
          '1aa408ff18afd5f5',
          '309eabed5e502727',
          '455d45581ec76703',
          'ea7755101b9d6ace',
          'fc57cb2f0c222208',
        ],
        'tag': null,
      },
      {
        'fingerprint': '6de6fe169aebe6f6',
        'tier': 'interactive',
        'role': 'button',
        'enabled': false,
        'aliases': ['54a246e465e78284'],
        'tag': null,
      },
      {
        'fingerprint': 'e685743c799ef7f7',
        'tier': 'interactive',
        'role': 'button',
        'enabled': true,
        'aliases': [
          '059fd4a17541b92b',
          'a3b29125d294afc8',
          'bba6126a7b85ca9c',
          'c03f28d11874906a',
          'c83f020fb8ed0dbd',
        ],
        'tag': null,
      },
      {
        'fingerprint': 'd68eab2b19ca1a9d',
        'tier': 'interactive',
        'role': 'button',
        'enabled': true,
        'aliases': [
          '19cb6de4fceebda4',
          '808c52ac6a0a9633',
          'b4e70e4419c043ab',
          'c441be8e49a00755',
        ],
        'tag': null,
      },
      {
        'fingerprint': '1437b855ce1eb9db',
        'tier': 'interactive',
        'role': 'button',
        'enabled': true,
        'aliases': [],
        'tag': null,
      },
      {
        'fingerprint': 'ccd9d6a2528b85c6',
        'tier': 'interactive',
        'role': 'button',
        'enabled': true,
        'aliases': [
          '1ba1664e631d8286',
          '356392d7a0ac9e68',
          '810519de8504c93d',
          'c09668a6d44b1cf9',
          'e0e906d439941143',
        ],
        'tag': 'cta',
      },
    ],
  },
};

/// Schema 6 output of the same fixture, observed in a worktree at 4f1b72e
/// (the commit before this wave). Each key is a schema 6 fingerprint and its
/// value is that entry's schema 6 aliases. They must survive as aliases.
const _schema6Observed = <String, Map<String, List<String>>>{
  'named': {
    'b81b3e59183ebd21': ['25b1b03b6a41028f', '6da905874663e646'],
    'd3b6f52768a94fd4': ['1e0730bd5f6bec07', '655f0d398ae48748'],
    'e72ca8effba2e941': ['5cbc415df9f25d9f'],
    '8b3fde97c2246047': ['b3e2cd635f763dc3', 'f22b6e97553c1759'],
  },
  'anonymous': {
    'ea7755101b9d6ace': ['1aa408ff18afd5f5', 'fc57cb2f0c222208'],
    '059fd4a17541b92b': ['bba6126a7b85ca9c', 'c03f28d11874906a'],
    'b4e70e4419c043ab': ['19cb6de4fceebda4'],
    '810519de8504c93d': ['356392d7a0ac9e68', 'c09668a6d44b1cf9'],
  },
};

Widget _goldenTree() => Padding(
  padding: const EdgeInsets.all(8),
  child: Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      FilledButton(onPressed: () {}, child: const Text('Save')),
      ElevatedButton(onPressed: null, child: const Text('Continue')),
      ListTile(onTap: () {}, title: const Text('Row')),
      Switch(value: false, onChanged: (_) {}),
      Semantics(onTap: () {}, child: const SizedBox(width: 60, height: 40)),
      TugboatTag(
        'cta',
        child: TextButton(onPressed: () {}, child: const Text('Tagged')),
      ),
    ],
  ),
);

Map<String, Object?> _describe(TugboatSceneInventory inventory) => {
  'routeKey': inventory.routeKey,
  'entries': [
    for (final entry in inventory.elements)
      {
        'fingerprint': entry.fingerprint,
        'tier': entry.tier,
        'role': entry.role,
        'enabled': entry.enabled,
        'aliases': entry.aliases,
        'tag': entry.tag,
      },
  ],
};

Future<Map<String, Object?>> _observe(WidgetTester tester) async {
  tester.view.physicalSize = const Size(800, 1200);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  final rootKey = GlobalKey();
  await tester.pumpWidget(
    MaterialApp(
      home: RepaintBoundary(
        key: rootKey,
        child: Scaffold(body: _goldenTree()),
      ),
    ),
  );
  await tester.pumpAndSettle();
  final resolver = AnchorResolver(rootKey: rootKey);
  TugboatSceneInventory build(String route) => resolver.buildSceneInventory(
    route: route,
    keyboardOpen: false,
    modalOpen: false,
    withBoundsEvidence: true,
  )!;
  return {
    'named': _describe(build('/golden')),
    'anonymous': _describe(build('MaterialPageRoute<dynamic>')),
  };
}

void main() {
  tearDown(TugboatReplay.resetForTest);

  testWidgets('golden fingerprints, route keys and aliases', (tester) async {
    final actual = await _observe(tester);
    expect(
      tugboatFingerprintSchemaVersion,
      _goldenSchemaVersion,
      reason:
          'fingerprint schema version changed: update _goldenSchemaVersion and this golden',
    );
    expect(
      jsonEncode(actual),
      jsonEncode(_goldenExpected),
      reason:
          'fingerprints changed: bump tugboatFingerprintSchemaVersion and update this golden',
    );
  });

  testWidgets('every schema 6 fingerprint survives as a schema 7 alias', (
    tester,
  ) async {
    final actual = await _observe(tester);
    for (final route in _schema6Observed.keys) {
      final entries =
          (actual[route]! as Map<String, Object?>)['entries']! as List;
      for (final MapEntry(key: fingerprint, value: aliases)
          in _schema6Observed[route]!.entries) {
        final match = entries.cast<Map<String, Object?>>().singleWhere(
          (entry) =>
              entry['fingerprint'] == fingerprint ||
              (entry['aliases']! as List).contains(fingerprint),
          orElse: () => fail('$route: schema 6 $fingerprint is not an alias'),
        );
        final carried = {match['fingerprint'], ...(match['aliases']! as List)};
        expect(carried, containsAll(aliases), reason: '$route: $fingerprint');
      }
    }
  });
}
