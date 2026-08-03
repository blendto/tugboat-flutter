import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tugboat/src/external_event.dart';
import 'package:tugboat/tugboat.dart';

const _testConfig = TugboatReplayConfig(
  profile: TugboatCaptureProfile.exploration,
  settleDelay: Duration.zero,
  interactionClaimWindow: Duration.zero,
  enableGlobalPointerCapture: false,
  capturePixelRatio: 1.0,
);

Future<void> _pumpCapture(WidgetTester tester) async {
  await tester.pumpWidget(
    MaterialApp(
      builder: (context, child) =>
          TugboatReplay.wrapApp(config: _testConfig, child: child!),
      home: const SizedBox.expand(),
    ),
  );
  await tester.pump();
}

void main() {
  tearDown(TugboatReplay.resetForTest);

  testWidgets('external event records once on evidence stream', (tester) async {
    await _pumpCapture(tester);
    final hook = TugboatReplay.eventHook(
      source: 'analytics',
      parameterPolicy: TugboatParameterPolicy.allowList({'method'}),
    );

    final parameters = <String, Object?>{'method': 'email', 'secret': 'nope'};
    hook.record('USER_LOGIN', parameters: parameters);
    parameters['method'] = 'mutated';

    final events = TugboatReplay.controller!.session!.events
        .where((e) => e.type == 'external_event')
        .toList();
    expect(events, hasLength(1));
    final event = events.single;
    expect(event.stream, TugboatEventStream.evidence);
    expect(event.isEnrichmentCandidate, isFalse);
    expect(event.actionId, isNull);
    expect(event.relatedEventId, isNull);
    expect(event.stateAnchor, isNull);
    expect(event.targetAnchor, isNull);
    expect(event.data['source'], 'analytics');
    expect(event.data['name'], 'USER_LOGIN');
    expect(event.data['parameterKeys'], ['method', 'secret']);
    expect(event.data['parameters'], {'method': 'email'});
    expect(event.data['capture'], {
      'values': 'allow_list',
      'truncated': false,
      'droppedCount': 1,
    });
  });

  testWidgets('names-only policy omits parameter values', (tester) async {
    await _pumpCapture(tester);
    TugboatReplay.eventHook().record(
      'SEARCH',
      parameters: {'query': 'chicken soup'},
    );

    final event = TugboatReplay.controller!.session!.events.singleWhere(
      (e) => e.type == 'external_event',
    );
    expect(event.data['parameterKeys'], ['query']);
    expect(event.data.containsKey('parameters'), isFalse);
    expect(event.data['capture'], {
      'values': 'names_only',
      'truncated': false,
      'droppedCount': 0,
    });
  });

  testWidgets('external event ignores active action window', (tester) async {
    await _pumpCapture(tester);
    final controller = TugboatReplay.controller!;
    controller.setExplorationActionWindow(
      explorationRunId: 'run-1',
      actionId: 'A-1',
    );

    TugboatReplay.eventHook(source: 'analytics').record('PING');
    final call = TugboatReplay.beginNetworkCall(
      method: 'GET',
      route: '/blend/:blendId',
    );
    call.complete(statusCode: 200);

    final external = controller.session!.events.singleWhere(
      (e) => e.type == 'external_event',
    );
    final network = controller.session!.events.singleWhere(
      (e) => e.type == 'network_call',
    );
    for (final event in [external, network]) {
      expect(event.actionId, isNull);
      expect(event.relatedEventId, isNull);
      expect(event.stateAnchor, isNull);
      expect(event.targetAnchor, isNull);
      expect(event.stream, TugboatEventStream.evidence);
    }
  });

  testWidgets('dormant hook and network calls are no-ops', (tester) async {
    expect(() {
      TugboatReplay.eventHook().record('X', parameters: {'a': 1});
      TugboatReplay.beginNetworkCall(
        method: 'GET',
        route: '/x',
      ).complete(statusCode: 200);
    }, returnsNormally);
    expect(TugboatReplay.controller, isNull);
  });

  testWidgets('transform failures drop values without throwing', (
    tester,
  ) async {
    await _pumpCapture(tester);
    final hook = TugboatReplay.eventHook(
      parameterPolicy: TugboatParameterPolicy.transform((key, value) {
        if (key == 'boom') throw StateError('nope');
        if (key == 'skip') return TugboatParameterPolicy.drop;
        return value;
      }),
    );

    expect(
      () => hook.record('EVT', parameters: {'ok': 1, 'boom': 'x', 'skip': 'y'}),
      returnsNormally,
    );

    final event = TugboatReplay.controller!.session!.events.singleWhere(
      (e) => e.type == 'external_event',
    );
    expect(event.data['parameters'], {'ok': 1});
    expect((event.data['capture'] as Map)['droppedCount'], 2);
  });

  testWidgets('network token finishes exactly once', (tester) async {
    await _pumpCapture(tester);
    final call = TugboatReplay.beginNetworkCall(
      method: 'post',
      route: '/cart/:cartId',
    );
    call.complete(statusCode: 201);
    call.fail(outcome: TugboatNetworkOutcome.networkError);
    call.complete(statusCode: 500);

    final events = TugboatReplay.controller!.session!.events
        .where((e) => e.type == 'network_call')
        .toList();
    expect(events, hasLength(1));
    expect(events.single.data['method'], 'POST');
    expect(events.single.data['route'], '/cart/:cartId');
    expect(events.single.data['statusCode'], 201);
    expect(events.single.data['outcome'], 'response');
    expect(events.single.data['durationMs'], isA<int>());
    expect(
      TugboatReplay.health.evidence.networkDuplicateFinishes,
      greaterThanOrEqualTo(2),
    );
  });

  testWidgets('empty route returns no-op without event', (tester) async {
    await _pumpCapture(tester);
    final call = TugboatReplay.beginNetworkCall(method: 'GET', route: '  ');
    call.complete(statusCode: 200);
    expect(
      TugboatReplay.controller!.session!.events.where(
        (e) => e.type == 'network_call',
      ),
      isEmpty,
    );
    expect(TugboatReplay.health.evidence.networkDropped, greaterThan(0));
  });

  test('parameter snapshot deep-copies and bounds nested values', () {
    final nested = <String, Object?>{
      'a': {
        'b': {
          'c': {
            'd': {'e': 'too-deep'},
          },
        },
      },
      'list': [1, 2, double.nan, Object()],
    };
    final snapshot = snapshotExternalParameters(
      policy: TugboatParameterPolicy.allowAll,
      parameters: nested,
    );
    nested['a'] = 'mutated';
    expect(snapshot.parameters!['a'], isA<Map>());
    expect(snapshot.truncated, isTrue);
    expect(snapshot.droppedCount, greaterThan(0));
    final encoded = snapshot.parameters.toString();
    expect(encoded.contains('too-deep'), isFalse);
    expect(encoded.contains('Object'), isFalse);
  });
}
