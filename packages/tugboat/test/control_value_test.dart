import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tugboat/tugboat.dart';

const _testConfig = TugboatReplayConfig(
  profile: TugboatCaptureProfile.exploration,
  settleDelay: Duration.zero,
  enableGlobalPointerCapture: false,
  capturePixelRatio: 1.0,
);

Future<void> _waitForCaptures(WidgetTester tester) async {
  await tester.pump();
  await tester.runAsync(() async {
    await Future<void>.delayed(const Duration(milliseconds: 300));
  });
  await tester.pump();
}

Map<String, Object?>? _controlValueFrom(TugboatEvent event) {
  final raw = event.data['controlValue'];
  if (raw is Map<String, Object?>) return raw;
  if (raw is Map) return Map<String, Object?>.from(raw);
  return null;
}

Map<String, Object?>? _semanticAnnotationFrom(TugboatEvent event) {
  final raw = event.data['semanticAnnotation'];
  if (raw is Map<String, Object?>) return raw;
  if (raw is Map) return Map<String, Object?>.from(raw);
  return null;
}

void main() {
  setUp(TugboatReplay.resetForTest);
  tearDown(TugboatReplay.resetForTest);

  group('tugboatControlValueForWidget', () {
    test('encodes bool and number literals', () {
      final checkbox = tugboatControlValueForWidget(
        Checkbox(value: true, onChanged: (_) {}),
      );
      expect(checkbox?.role, 'checkbox');
      expect(checkbox?.value?.kind, 'bool');
      expect(checkbox?.value?.value, isTrue);

      final slider = tugboatControlValueForWidget(
        Slider(value: 0.4, onChanged: (_) {}),
      );
      expect(slider?.role, 'slider');
      expect(slider?.value?.kind, 'number');
      expect(slider?.value?.value, 0.4);
    });

    test('hashes free-text option strings and keeps developer tokens', () {
      final freeText = TugboatEncodedControlScalar.encode('Secret Option Name');
      expect(freeText.kind, 'token');
      expect(freeText.value, startsWith('str:'));
      expect(freeText.value, isNot(contains('Secret')));
      expect(freeText.length, 'Secret Option Name'.length);

      final token = TugboatEncodedControlScalar.encode('usd');
      expect(token.kind, 'token');
      expect(token.value, 'usd');
    });

    test('reads radio option identity and group selection', () {
      final radio = tugboatControlValueForWidget(
        // ignore: deprecated_member_use
        Radio<int>(
          value: 2,
          // ignore: deprecated_member_use
          groupValue: 1,
          // ignore: deprecated_member_use
          onChanged: (_) {},
        ),
      );
      expect(radio?.role, 'radio');
      expect(radio?.value?.value, 2);
      expect(radio?.groupValue?.value, 1);
      expect(radio?.selected, isFalse);
    });
  });

  testWidgets('switch tap emits before/after control values', (tester) async {
    var enabled = false;
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) =>
            TugboatReplay.wrapApp(config: _testConfig, child: child!),
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) {
              return Switch(
                key: const Key('notify-switch'),
                value: enabled,
                onChanged: (next) => setState(() => enabled = next),
              );
            },
          ),
        ),
      ),
    );
    await _waitForCaptures(tester);

    await tester.tap(find.byKey(const Key('notify-switch')));
    await _waitForCaptures(tester);

    final session = TugboatReplay.controller!.session!;
    final tap = session.events.firstWhere((e) => e.type == 'tap');
    final settled = session.events.firstWhere((e) => e.type == 'tap_settled');

    final tapValue = _controlValueFrom(tap);
    expect(tapValue?['role'], 'switch');
    expect((tapValue?['value'] as Map)['value'], isFalse);

    final settledValue = _controlValueFrom(settled);
    expect(settledValue?['role'], 'switch');
    expect((settledValue?['before'] as Map)['value'], isA<Map>());
    expect(
      ((settledValue?['before'] as Map)['value'] as Map)['value'],
      isFalse,
    );
    expect(((settledValue?['after'] as Map)['value'] as Map)['value'], isTrue);
    expect(enabled, isTrue);
  });

  testWidgets('radio tap records which option was selected', (tester) async {
    int? selected = 1;
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) =>
            TugboatReplay.wrapApp(config: _testConfig, child: child!),
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) {
              return Column(
                children: [
                  // ignore: deprecated_member_use
                  RadioListTile<int>(
                    key: const Key('radio-1'),
                    title: const Text('One'),
                    value: 1,
                    // ignore: deprecated_member_use
                    groupValue: selected,
                    // ignore: deprecated_member_use
                    onChanged: (next) => setState(() => selected = next),
                  ),
                  // ignore: deprecated_member_use
                  RadioListTile<int>(
                    key: const Key('radio-2'),
                    title: const Text('Two'),
                    value: 2,
                    // ignore: deprecated_member_use
                    groupValue: selected,
                    // ignore: deprecated_member_use
                    onChanged: (next) => setState(() => selected = next),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
    await _waitForCaptures(tester);

    await tester.tap(find.byKey(const Key('radio-2')));
    await _waitForCaptures(tester);

    final session = TugboatReplay.controller!.session!;
    final tap = session.events.firstWhere((e) => e.type == 'tap');
    final tapValue = _controlValueFrom(tap)!;
    expect(tapValue['role'], 'radio');
    expect((tapValue['value'] as Map)['value'], 2);
    expect((tapValue['groupValue'] as Map)['value'], 1);
    expect(tapValue['selected'], isFalse);
    expect(tapValue['index'], 1);

    final settled = session.events.firstWhere((e) => e.type == 'tap_settled');
    final settledValue = _controlValueFrom(settled)!;
    expect(((settledValue['after'] as Map)['value'] as Map)['value'], 2);
    expect(((settledValue['after'] as Map)['groupValue'] as Map)['value'], 2);
    expect((settledValue['after'] as Map)['selected'], isTrue);
    expect(selected, 2);
  });

  testWidgets('dropdown item tap records the chosen option value', (
    tester,
  ) async {
    var selected = 1;
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) =>
            TugboatReplay.wrapApp(config: _testConfig, child: child!),
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) {
              return DropdownButton<int>(
                key: const Key('plan-dropdown'),
                value: selected,
                items: const [
                  DropdownMenuItem(value: 1, child: Text('Starter')),
                  DropdownMenuItem(value: 2, child: Text('Pro')),
                ],
                onChanged: (next) {
                  if (next != null) setState(() => selected = next);
                },
              );
            },
          ),
        ),
      ),
    );
    await _waitForCaptures(tester);

    await tester.tap(find.byKey(const Key('plan-dropdown')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Pro').last);
    await _waitForCaptures(tester);

    final session = TugboatReplay.controller!.session!;
    final itemTaps = session.events
        .where((e) => e.type == 'tap')
        .map(_controlValueFrom)
        .where((value) => value?['role'] == 'dropdownItem')
        .toList();
    expect(itemTaps, isNotEmpty);
    expect((itemTaps.last!['value'] as Map)['value'], 2);
    expect(selected, 2);
  });

  testWidgets('slider drag swipe records numeric value', (tester) async {
    var value = 0.0;
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) =>
            TugboatReplay.wrapApp(config: _testConfig, child: child!),
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) {
              return Slider(
                key: const Key('volume-slider'),
                value: value,
                onChanged: (next) => setState(() => value = next),
              );
            },
          ),
        ),
      ),
    );
    await _waitForCaptures(tester);

    await tester.drag(
      find.byKey(const Key('volume-slider')),
      const Offset(80, 0),
    );
    await _waitForCaptures(tester);

    final session = TugboatReplay.controller!.session!;
    final swipes = session.events.where((e) => e.type == 'swipe').toList();
    expect(swipes, isNotEmpty);
    final controlValue = _controlValueFrom(swipes.last);
    expect(controlValue?['role'], 'slider');
    expect((controlValue?['value'] as Map)['kind'], 'number');
    expect((controlValue?['value'] as Map)['value'], isA<num>());
    expect(value, greaterThan(0));
  });

  testWidgets('cupertino switch values are captured', (tester) async {
    var enabled = true;
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) =>
            TugboatReplay.wrapApp(config: _testConfig, child: child!),
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) {
              return CupertinoSwitch(
                key: const Key('cupertino-switch'),
                value: enabled,
                onChanged: (next) => setState(() => enabled = next),
              );
            },
          ),
        ),
      ),
    );
    await _waitForCaptures(tester);

    await tester.tap(find.byKey(const Key('cupertino-switch')));
    await _waitForCaptures(tester);

    final tap = TugboatReplay.controller!.session!.events.firstWhere(
      (e) => e.type == 'tap',
    );
    final tapValue = _controlValueFrom(tap);
    expect(tapValue?['role'], 'switch');
    expect((tapValue?['value'] as Map)['value'], isTrue);
  });

  testWidgets('free-text dropdown values stay hashed in session json', (
    tester,
  ) async {
    var selected = 'alpha-code';
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) =>
            TugboatReplay.wrapApp(config: _testConfig, child: child!),
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) {
              return DropdownButton<String>(
                value: selected,
                items: const [
                  DropdownMenuItem(value: 'alpha-code', child: Text('Alpha')),
                  DropdownMenuItem(
                    value: 'Visible Secret City Name',
                    child: Text('Beta'),
                  ),
                ],
                onChanged: (next) {
                  if (next != null) setState(() => selected = next);
                },
              );
            },
          ),
        ),
      ),
    );
    await _waitForCaptures(tester);

    await tester.tap(find.byType(DropdownButton<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Beta').last);
    await _waitForCaptures(tester);

    final json = TugboatReplay.controller!.session!.toJson().toString();
    expect(json, isNot(contains('Visible Secret City Name')));
    expect(json, contains('str:'));
  });

  test('semantic properties encode value and label tokens', () {
    final snapshot = tugboatControlValueFromSemanticsProperties(
      const SemanticsProperties(
        button: true,
        value: '15',
        label: 'Duration fifteen seconds',
        selected: true,
      ),
    );
    expect(snapshot?.role, 'button');
    expect(snapshot?.sources, ['semantics']);
    expect(snapshot?.value?.kind, 'number');
    expect(snapshot?.value?.value, 15);
    expect(snapshot?.semanticValue?.value, 15);
    expect(snapshot?.semanticLabel?.value, startsWith('str:'));
    expect(snapshot?.selected, isTrue);
  });

  testWidgets('custom gesture detector list captures semantic value/label', (
    tester,
  ) async {
    String? selected;
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) =>
            TugboatReplay.wrapApp(config: _testConfig, child: child!),
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) {
              return Column(
                children: [
                  Semantics(
                    button: true,
                    identifier: 'duration-15',
                    value: '15',
                    label: 'Duration 15 seconds',
                    selected: selected == '15',
                    child: GestureDetector(
                      key: const Key('duration-15'),
                      onTap: () => setState(() => selected = '15'),
                      child: const Text('15 seconds'),
                    ),
                  ),
                  Semantics(
                    button: true,
                    identifier: 'duration-30',
                    value: '30',
                    label: 'Duration 30 seconds',
                    selected: selected == '30',
                    child: GestureDetector(
                      key: const Key('duration-30'),
                      onTap: () => setState(() => selected = '30'),
                      child: const Text('30 seconds'),
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
    await _waitForCaptures(tester);

    await tester.tap(find.byKey(const Key('duration-30')));
    await _waitForCaptures(tester);

    final session = TugboatReplay.controller!.session!;
    final tap = session.events.firstWhere((e) => e.type == 'tap');
    final tapValue = _controlValueFrom(tap)!;
    expect(tapValue['sources'], contains('semantics'));
    expect((tapValue['semanticValue'] as Map)['value'], 30);
    expect((tapValue['value'] as Map)['value'], 30);
    expect((tapValue['semanticLabel'] as Map)['value'], startsWith('str:'));
    expect(tapValue.toString(), isNot(contains('Duration 30 seconds')));

    final annotation = _semanticAnnotationFrom(tap)!;
    expect(annotation['role'], 'button');
    expect((annotation['identifier'] as Map)['value'], 'duration-30');
    expect((annotation['value'] as Map)['value'], 30);
    expect((annotation['label'] as Map)['value'], startsWith('str:'));
    expect(selected, '30');
  });

  testWidgets('button taps emit semanticAnnotation labels', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) =>
            TugboatReplay.wrapApp(config: _testConfig, child: child!),
        home: Scaffold(
          body: FilledButton(
            key: const Key('generate-cta'),
            onPressed: () {},
            child: const Text('Generate'),
          ),
        ),
      ),
    );
    await _waitForCaptures(tester);

    await tester.tap(find.byKey(const Key('generate-cta')));
    await _waitForCaptures(tester);

    final session = TugboatReplay.controller!.session!;
    final tap = session.events.firstWhere((e) => e.type == 'tap');
    final settled = session.events.firstWhere((e) => e.type == 'tap_settled');
    final tapSemantic = _semanticAnnotationFrom(tap);
    final settledSemantic = _semanticAnnotationFrom(settled);

    expect(tapSemantic, isNotNull);
    expect(tapSemantic?['role'], 'button');
    expect((tapSemantic?['label'] as Map)['value'], 'Generate');
    expect(settledSemantic, isNotNull);
    expect((settledSemantic?['label'] as Map)['value'], 'Generate');
  });

  testWidgets('scroll events carry semanticAnnotation when present', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) =>
            TugboatReplay.wrapApp(config: _testConfig, child: child!),
        home: Scaffold(
          body: Semantics(
            identifier: 'preset-list',
            label: 'Preset options',
            child: ListView(
              key: const Key('preset-list'),
              children: [
                for (var i = 0; i < 30; i++) ListTile(title: Text('Preset $i')),
              ],
            ),
          ),
        ),
      ),
    );
    await _waitForCaptures(tester);

    await tester.drag(
      find.byKey(const Key('preset-list')),
      const Offset(0, -200),
    );
    await _waitForCaptures(tester);

    final session = TugboatReplay.controller!.session!;
    final scrollEvents = session.events
        .where((e) => e.type == 'scroll_start' || e.type == 'scroll_end')
        .toList();
    expect(scrollEvents, isNotEmpty);
    final annotated = scrollEvents
        .map(_semanticAnnotationFrom)
        .whereType<Map<String, Object?>>()
        .toList();
    expect(annotated, isNotEmpty);
    expect(
      annotated.any((annotation) {
        final identifier = annotation['identifier'];
        return identifier is Map && identifier['value'] == 'preset-list';
      }),
      isTrue,
    );
  });
}
