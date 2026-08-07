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

Future<void> _pumpCapture(
  WidgetTester tester, {
  TugboatReplayConfig config = _testConfig,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      builder: (context, child) =>
          TugboatReplay.wrapApp(config: config, child: child!),
      home: const SizedBox.expand(),
    ),
  );
  await tester.pump();
}

class _CallbackSinkFactory implements TugboatCaptureSinkFactory {
  _CallbackSinkFactory(this.onEvent);

  final void Function(TugboatEvent event) onEvent;

  @override
  TugboatSessionCaptureSink create(TugboatSinkSessionContext context) =>
      _CallbackSink(onEvent);
}

class _CallbackSink implements TugboatSessionCaptureSink {
  _CallbackSink(this.onEvent);

  final void Function(TugboatEvent event) onEvent;

  @override
  void accept(TugboatCaptureEnvelope envelope) {
    final event = envelope.event;
    if (event != null) onEvent(event);
  }

  @override
  Future<void> dispose() async {}

  @override
  Future<void> finish() async {}

  @override
  Future<void> flush() async {}

  @override
  Future<void> start(TugboatSinkSessionContext context) async {}
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

  testWidgets('production capture downgrades allow-all to names-only', (
    tester,
  ) async {
    await _pumpCapture(
      tester,
      config: _testConfig.copyWith(
        profile: TugboatCaptureProfile.productionLean,
      ),
    );

    TugboatReplay.eventHook(
      parameterPolicy: TugboatParameterPolicy.allowAll,
    ).record('SEARCH', parameters: {'query': 'private search'});

    final event = TugboatReplay.controller!.session!.events.singleWhere(
      (event) => event.type == 'external_event',
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

  testWidgets('transform cannot append after synchronously ending session', (
    tester,
  ) async {
    await _pumpCapture(tester);
    final controller = TugboatReplay.controller!;
    final session = controller.session!;
    final hook = TugboatReplay.eventHook(
      parameterPolicy: TugboatParameterPolicy.transform((key, value) {
        controller.endSession();
        return value;
      }),
    );

    hook.record('AFTER_END', parameters: {'trigger': true});

    expect(
      session.events.where((event) => event.type == 'external_event'),
      isEmpty,
    );
    expect(
      session.events.where((event) => event.type == 'session_end'),
      hasLength(1),
    );
    expect(TugboatReplay.health.evidence.externalAccepted, 0);
    expect(TugboatReplay.health.evidence.externalDropped, 1);
    expect(TugboatReplay.health.evidence.lastDropReason, 'no_active_session');
  });

  testWidgets('transform cannot append into a replacement session', (
    tester,
  ) async {
    await _pumpCapture(tester);
    final controller = TugboatReplay.controller!;
    final originalSession = controller.session!;
    final hook = TugboatReplay.eventHook(
      parameterPolicy: TugboatParameterPolicy.transform((key, value) {
        controller.clear();
        return value;
      }),
    );

    hook.record('AFTER_CLEAR', parameters: {'trigger': true});

    final replacementSession = controller.session!;
    expect(replacementSession.id, isNot(originalSession.id));
    expect(
      originalSession.events.where((event) => event.type == 'external_event'),
      isEmpty,
    );
    expect(
      replacementSession.events.where(
        (event) => event.type == 'external_event',
      ),
      isEmpty,
    );
    expect(TugboatReplay.health.evidence.externalAccepted, 0);
    expect(TugboatReplay.health.evidence.externalDropped, 1);
    expect(TugboatReplay.health.evidence.lastDropReason, 'stale_session');
  });

  testWidgets('network token finishes exactly once', (tester) async {
    await _pumpCapture(tester);
    final call = TugboatReplay.beginNetworkCall(
      method: 'post',
      route: '/cart/:cartId',
    );
    call.complete(statusCode: 201);
    call.fail(failure: TugboatNetworkFailure.networkError);
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

  testWidgets('network call retains a copied HTTP error response body', (
    tester,
  ) async {
    await _pumpCapture(tester);
    final body = <String, Object?>{
      'code': 'invalid_project',
      'details': <Object?>['missing_name'],
    };

    TugboatReplay.beginNetworkCall(
      method: 'POST',
      route: '/projects',
    ).complete(statusCode: 422, errorResponseBody: body);
    body['code'] = 'mutated';
    (body['details'] as List<Object?>).add('mutated');

    final event = TugboatReplay.controller!.session!.events.singleWhere(
      (event) => event.type == 'network_call',
    );
    expect(event.data['errorResponseBody'], {
      'code': 'invalid_project',
      'details': ['missing_name'],
    });
    expect(event.data['errorResponseBodyCapture'], {
      'format': 'json',
      'representation': 'native',
      'truncated': false,
    });
  });

  testWidgets('network call never retains a successful response body', (
    tester,
  ) async {
    await _pumpCapture(tester);

    TugboatReplay.beginNetworkCall(
      method: 'GET',
      route: '/projects',
    ).complete(statusCode: 200, errorResponseBody: {'secret': 'success-body'});

    final event = TugboatReplay.controller!.session!.events.singleWhere(
      (event) => event.type == 'network_call',
    );
    expect(event.data.containsKey('errorResponseBody'), isFalse);
    expect(event.data.toString(), isNot(contains('success-body')));
  });

  testWidgets('network error response text is bounded', (tester) async {
    await _pumpCapture(tester);

    TugboatReplay.beginNetworkCall(method: 'GET', route: '/projects').complete(
      statusCode: 500,
      errorResponseBody:
          'x' * (TugboatNetworkLimits.maxErrorResponseBodyBytes + 100),
    );

    final event = TugboatReplay.controller!.session!.events.singleWhere(
      (event) => event.type == 'network_call',
    );
    expect(
      (event.data['errorResponseBody'] as String).length,
      TugboatNetworkLimits.maxErrorResponseBodyBytes,
    );
    expect(event.data['errorResponseBodyCapture'], {
      'format': 'text',
      'representation': 'native',
      'truncated': true,
    });
  });

  testWidgets('network call omits binary error response bodies', (
    tester,
  ) async {
    await _pumpCapture(tester);

    TugboatReplay.beginNetworkCall(
      method: 'GET',
      route: '/download',
    ).complete(statusCode: 500, errorResponseBody: <int>[0, 1, 2, 3]);

    final event = TugboatReplay.controller!.session!.events.singleWhere(
      (event) => event.type == 'network_call',
    );
    expect(event.data.containsKey('errorResponseBody'), isFalse);
  });

  testWidgets('network token cannot finish into a replacement session', (
    tester,
  ) async {
    await _pumpCapture(tester);
    final controller = TugboatReplay.controller!;
    final staleCall = TugboatReplay.beginNetworkCall(
      method: 'GET',
      route: '/stale',
    );

    controller.start(const Size(320, 640), 'replacement');
    staleCall.complete(statusCode: 200);
    staleCall.complete(statusCode: 500);

    expect(
      controller.session!.events.where((e) => e.type == 'network_call'),
      isEmpty,
    );
    expect(TugboatReplay.health.evidence.networkAccepted, 0);
    expect(TugboatReplay.health.evidence.networkDropped, 1);
    expect(TugboatReplay.health.evidence.networkDuplicateFinishes, 0);
    expect(TugboatReplay.health.evidence.lastDropReason, 'stale_session');

    TugboatReplay.beginNetworkCall(
      method: 'GET',
      route: '/current',
    ).complete(statusCode: 204);
    final current = controller.session!.events.singleWhere(
      (e) => e.type == 'network_call',
    );
    expect(current.data['route'], '/current');
    expect(current.data['statusCode'], 204);
  });

  testWidgets('clear fences in-flight network tokens', (tester) async {
    await _pumpCapture(tester);
    final controller = TugboatReplay.controller!;
    final staleCall = TugboatReplay.beginNetworkCall(
      method: 'POST',
      route: '/before-clear',
    );

    controller.clear();
    staleCall.fail(failure: TugboatNetworkFailure.networkError);

    expect(
      controller.session!.events.where((e) => e.type == 'network_call'),
      isEmpty,
    );
    expect(TugboatReplay.health.evidence.networkAccepted, 0);
    expect(TugboatReplay.health.evidence.networkDropped, 1);
    expect(TugboatReplay.health.evidence.lastDropReason, 'stale_session');
  });

  testWidgets('session end rejects evidence during sink reentrancy', (
    tester,
  ) async {
    final factory = _CallbackSinkFactory((event) {
      if (event.type != 'session_end') return;
      // Host-facing APIs must no-op once evidence is fenced, even when the
      // lifecycle has not yet moved to stopping.
      TugboatReplay.eventHook().record('AFTER_SESSION_END');
      TugboatReplay.beginNetworkCall(
        method: 'GET',
        route: '/after-end',
      ).complete(statusCode: 200);
    });
    await _pumpCapture(
      tester,
      config: _testConfig.copyWith(sinkFactories: [factory]),
    );
    final controller = TugboatReplay.controller!;

    await controller.endSession();

    final eventTypes = controller.session!.events.map((event) => event.type);
    expect(eventTypes.where((type) => type == 'session_end'), hasLength(1));
    expect(eventTypes, isNot(contains('external_event')));
    expect(eventTypes, isNot(contains('network_call')));
    expect(controller.acceptingEvidence, isFalse);
    expect(TugboatReplay.isAcceptingEvidence, isFalse);
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

  testWidgets('unsafe route forms return no-op without retaining URL data', (
    tester,
  ) async {
    await _pumpCapture(tester);
    for (final route in [
      'https://example.test/users/42?token=secret',
      '/users/42?token=secret',
      '/users/42#fragment',
      '/users/42%3Ftoken%3Dsecret',
      'users/42',
      '//example.test/users/42',
      ' /users/42',
      '/users/42 ',
      '/users/42\\details',
    ]) {
      TugboatReplay.beginNetworkCall(
        method: 'GET',
        route: route,
      ).complete(statusCode: 200);
    }

    expect(
      TugboatReplay.controller!.session!.events.where(
        (e) => e.type == 'network_call',
      ),
      isEmpty,
    );
    expect(TugboatReplay.health.evidence.networkDropped, 9);
    expect(TugboatReplay.health.toJson().toString().contains('secret'), false);
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

  test('unsupported top-level value counts as one drop', () {
    final snapshot = snapshotExternalParameters(
      policy: TugboatParameterPolicy.allowAll,
      parameters: {'unsupported': Object()},
    );

    expect(snapshot.parameters, isNull);
    expect(snapshot.truncated, isTrue);
    expect(snapshot.droppedCount, 1);
  });

  test('aggregate byte budget drops all values but retains keys', () {
    final parameters = <String, Object?>{
      for (var i = 0; i < 17; i++) 'key$i': 'x' * 1024,
    };
    final snapshot = snapshotExternalParameters(
      policy: TugboatParameterPolicy.allowAll,
      parameters: parameters,
    );

    expect(snapshot.parameterKeys, parameters.keys);
    expect(snapshot.parameters, isNull);
    expect(snapshot.truncated, isTrue);
    expect(snapshot.droppedCount, parameters.length);
  });
}
