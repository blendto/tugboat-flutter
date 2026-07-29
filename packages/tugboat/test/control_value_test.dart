import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tugboat/tugboat.dart';

const _testConfig = TugboatReplayConfig(
  profile: TugboatCaptureProfile.exploration,
  settleDelay: Duration.zero,
  interactionClaimWindow: Duration.zero,
  enableGlobalPointerCapture: false,
  capturePixelRatio: 1.0,
);

const _canonicalTestConfig = TugboatReplayConfig(
  profile: TugboatCaptureProfile.exploration,
  settleDelay: Duration.zero,
  interactionClaimWindow: Duration.zero,
  interactionPublishMode: TugboatInteractionPublishMode.canonicalOnly,
  enableGlobalPointerCapture: false,
  capturePixelRatio: 1.0,
);

class _SemanticsOnlyControl extends LeafRenderObjectWidget {
  const _SemanticsOnlyControl({super.key, required this.value});

  final String value;

  @override
  _SemanticsOnlyRenderBox createRenderObject(BuildContext context) =>
      _SemanticsOnlyRenderBox(value);

  @override
  void updateRenderObject(
    BuildContext context,
    _SemanticsOnlyRenderBox renderObject,
  ) {
    renderObject.value = value;
  }
}

class _SemanticsOnlyRenderBox extends RenderBox {
  _SemanticsOnlyRenderBox(this._value);

  String _value;

  set value(String next) {
    if (_value == next) return;
    _value = next;
    markNeedsSemanticsUpdate();
  }

  @override
  bool get sizedByParent => true;

  @override
  void performResize() {
    size = constraints.constrain(const Size(120, 48));
  }

  @override
  bool hitTestSelf(Offset position) => true;

  @override
  void describeSemanticsConfiguration(SemanticsConfiguration config) {
    super.describeSemanticsConfiguration(config);
    config
      ..isSemanticBoundary = true
      ..isButton = true
      ..textDirection = TextDirection.ltr
      ..label = 'Semantics only control'
      ..value = _value
      ..onTap = () {};
  }
}

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

Map<String, Object?>? _controlValueTransitionFrom(TugboatEvent event) {
  final raw = event.data['controlValueTransition'];
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

    test('keeps raw string scalars visible', () {
      final freeText = TugboatEncodedControlScalar.encode('Secret Option Name');
      expect(freeText.kind, 'string');
      expect(freeText.value, 'Secret Option Name');

      final oneWordName = TugboatEncodedControlScalar.encode('Alice');
      expect(oneWordName.value, 'Alice');

      final numericPii = TugboatEncodedControlScalar.encode('123456');
      expect(numericPii.value, '123456');

      final whitespace = TugboatEncodedControlScalar.encode('  value  ');
      expect(whitespace.value, '  value  ');
      final empty = TugboatEncodedControlScalar.encode('');
      expect(empty.toJson(), {'kind': 'string', 'value': ''});

      final implicitIdentifier =
          TugboatEncodedControlScalar.encodeDeveloperToken('123456');
      expect(implicitIdentifier.value, '123456');

      final explicitIdentifier =
          TugboatEncodedControlScalar.encodeDeveloperToken(
            'tugboat:duration-30',
          );
      expect(explicitIdentifier.value, 'duration-30');
    });

    test('keeps encoded numbers JSON-safe', () {
      for (final value in [
        double.nan,
        double.infinity,
        double.negativeInfinity,
      ]) {
        final encoded = TugboatEncodedControlScalar.encode(value);
        expect(encoded.kind, isNot('number'));
        expect(() => encoded.toJson(), returnsNormally);
      }
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

    test('keeps explicitly declared safe values visible', () {
      final duration = TugboatVisibleControlValue.duration(
        const Duration(seconds: 15),
      );
      final template = TugboatVisibleControlValue.enumId('modern-minimal');

      expect(duration.toJson(), {'kind': 'duration_ms', 'value': 15000});
      expect(template.toJson(), {'kind': 'enum', 'value': 'modern-minimal'});
    });
  });

  testWidgets('developer value scope preserves an explicit slider value', (
    tester,
  ) async {
    var value = 0.25;
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) =>
            TugboatReplay.wrapApp(config: _testConfig, child: child!),
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) => TugboatControlValueScope(
              controlKey: 'text_curve',
              value: TugboatVisibleControlValue.number(value),
              role: 'slider',
              unit: 'ratio',
              min: 0,
              max: 1,
              step: 0.01,
              child: Slider(
                key: const Key('visible-slider'),
                value: value,
                onChanged: (next) => setState(() => value = next),
              ),
            ),
          ),
        ),
      ),
    );
    await _waitForCaptures(tester);

    await tester.tapAt(
      tester.getCenter(find.byKey(const Key('visible-slider'))) +
          const Offset(70, 0),
    );
    await _waitForCaptures(tester);

    final settled = TugboatReplay.controller!.session!.events.firstWhere(
      (event) => event.type == 'tap_settled',
    );
    final transition = _controlValueTransitionFrom(settled)!;
    final before = transition['before'] as Map;
    final after = transition['after'] as Map;

    expect(before['controlKey'], 'text_curve');
    expect(before['unit'], 'ratio');
    expect((before['min'] as Map)['value'], 0);
    expect((before['max'] as Map)['value'], 1);
    expect((before['step'] as Map)['value'], 0.01);
    expect((before['value'] as Map)['kind'], 'number');
    expect((before['value'] as Map)['value'], 0.25);
    expect((after['value'] as Map)['kind'], 'number');
    expect((after['value'] as Map)['value'], isNot(0.25));
  });

  testWidgets('invalid developer range metadata is not emitted', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) =>
            TugboatReplay.wrapApp(config: _testConfig, child: child!),
        home: Scaffold(
          body: TugboatControlValueScope(
            controlKey: 'text_curve',
            value: TugboatVisibleControlValue.number(0.5),
            min: 1,
            max: 0,
            step: 0,
            child: Slider(
              key: const Key('invalid-range-slider'),
              value: 0.5,
              onChanged: (_) {},
            ),
          ),
        ),
      ),
    );
    await _waitForCaptures(tester);

    await tester.tap(find.byKey(const Key('invalid-range-slider')));
    await _waitForCaptures(tester);

    final tap = TugboatReplay.controller!.session!.events.firstWhere(
      (event) => event.type == 'tap',
    );
    final controlValue = _controlValueFrom(tap)!;
    expect(controlValue, isNot(contains('controlKey')));
    expect(controlValue, isNot(contains('min')));
  });

  testWidgets('retains raw semantic values across capture sessions', (
    tester,
  ) async {
    Future<Object?> captureHash() async {
      final targetKey = UniqueKey();
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) =>
              TugboatReplay.wrapApp(config: _testConfig, child: child!),
          home: Scaffold(
            body: Center(
              child: Semantics(
                value: 'Alice',
                child: ElevatedButton(
                  key: targetKey,
                  onPressed: () {},
                  child: const Text('Capture'),
                ),
              ),
            ),
          ),
        ),
      );
      await _waitForCaptures(tester);
      await tester.tap(find.byKey(targetKey));
      await _waitForCaptures(tester);
      final tap = TugboatReplay.controller!.session!.events.firstWhere(
        (event) => event.type == 'tap',
      );
      return ((_semanticAnnotationFrom(tap)!['value'] as Map)['value']);
    }

    final first = await captureHash();
    await tester.pumpWidget(const SizedBox());
    TugboatReplay.resetForTest();
    final second = await captureHash();

    expect(first, 'Alice');
    expect(second, 'Alice');
  });

  testWidgets('controllers retain equivalent raw semantic values', (
    tester,
  ) async {
    final firstKey = GlobalKey();
    final secondKey = GlobalKey();
    await tester.pumpWidget(
      MaterialApp(
        home: Row(
          children: [
            Expanded(
              child: RepaintBoundary(
                key: firstKey,
                child: Semantics(
                  button: true,
                  value: 'Alice',
                  child: const SizedBox.expand(),
                ),
              ),
            ),
            Expanded(
              child: RepaintBoundary(
                key: secondKey,
                child: Semantics(
                  button: true,
                  value: 'Alice',
                  child: const SizedBox.expand(),
                ),
              ),
            ),
          ],
        ),
      ),
    );

    final firstController = TugboatReplayController(
      config: _testConfig,
      boundaryKey: firstKey,
    );
    final secondController = TugboatReplayController(
      config: _testConfig,
      boundaryKey: secondKey,
    );
    await firstController.initialize();
    await secondController.initialize();

    firstController.start(const Size(400, 600), 'test');
    await tester.pump();
    firstController.recordPointerDown(
      tester.getCenter(find.byKey(firstKey)),
      pointer: 1,
    );
    firstController.recordPointerUp(
      tester.getCenter(find.byKey(firstKey)),
      pointer: 1,
    );
    final firstTap = firstController.session!.events.lastWhere(
      (event) => event.type == 'tap',
    );
    final firstHash =
        ((_semanticAnnotationFrom(firstTap)!['value'] as Map)['value']);

    secondController.start(const Size(400, 600), 'test');
    await tester.pump();
    firstController.recordPointerDown(
      tester.getCenter(find.byKey(firstKey)),
      pointer: 2,
    );
    firstController.recordPointerUp(
      tester.getCenter(find.byKey(firstKey)),
      pointer: 2,
    );
    final secondTap = firstController.session!.events.lastWhere(
      (event) => event.type == 'tap',
    );
    final secondHash =
        ((_semanticAnnotationFrom(secondTap)!['value'] as Map)['value']);

    expect(firstHash, secondHash);
    firstController.dispose();
    secondController.dispose();
    await tester.pumpWidget(const SizedBox());
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

    final settledValue = _controlValueTransitionFrom(settled);
    expect(settledValue?['role'], 'switch');
    expect(
      settledValue?['schemaVersion'],
      tugboatControlValueTransitionSchemaVersion,
    );
    expect(settled.data, isNot(contains('controlValue')));
    expect((settledValue?['before'] as Map)['value'], isA<Map>());
    expect(
      (settledValue?['before'] as Map)['schemaVersion'],
      tugboatControlValueSchemaVersion,
    );
    expect(
      (settledValue?['after'] as Map)['schemaVersion'],
      tugboatControlValueSchemaVersion,
    );
    expect(
      ((settledValue?['before'] as Map)['value'] as Map)['value'],
      isFalse,
    );
    expect(((settledValue?['after'] as Map)['value'] as Map)['value'], isTrue);
    expect(enabled, isTrue);
  });

  testWidgets('canonical-only tap retains the control transition', (
    tester,
  ) async {
    var enabled = false;
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) =>
            TugboatReplay.wrapApp(config: _canonicalTestConfig, child: child!),
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) => Switch(
              key: const Key('canonical-switch'),
              value: enabled,
              onChanged: (next) => setState(() => enabled = next),
            ),
          ),
        ),
      ),
    );
    await _waitForCaptures(tester);

    await tester.tap(find.byKey(const Key('canonical-switch')));
    await _waitForCaptures(tester);

    final session = TugboatReplay.controller!.session!;
    expect(
      session.events.where((event) => event.type == 'tap_settled'),
      isEmpty,
    );
    final interaction = session.events.firstWhere(
      (event) => event.type == 'interaction',
    );
    final result = Map<String, Object?>.from(
      interaction.data['result']! as Map,
    );
    final transition = Map<String, Object?>.from(
      result['controlValueTransition']! as Map,
    );
    expect(transition['role'], 'switch');
    expect(((transition['before'] as Map)['value'] as Map)['value'], isFalse);
    expect(((transition['after'] as Map)['value'] as Map)['value'], isTrue);
  });

  testWidgets('canonical-only swipe retains final control metadata', (
    tester,
  ) async {
    var value = 0.0;
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) =>
            TugboatReplay.wrapApp(config: _canonicalTestConfig, child: child!),
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) => Slider(
              key: const Key('canonical-slider'),
              value: value,
              onChanged: (next) => setState(() => value = next),
            ),
          ),
        ),
      ),
    );
    await _waitForCaptures(tester);

    await tester.drag(
      find.byKey(const Key('canonical-slider')),
      const Offset(80, 0),
    );
    await _waitForCaptures(tester);

    final session = TugboatReplay.controller!.session!;
    expect(session.events.where((event) => event.type == 'swipe'), isEmpty);
    final interaction = session.events.firstWhere(
      (event) =>
          event.type == 'interaction' &&
          (event.data['gesture'] == 'swipe' ||
              event.data['gesture'] == 'scroll'),
    );
    final result = Map<String, Object?>.from(
      interaction.data['result']! as Map,
    );
    final controlValue = Map<String, Object?>.from(
      result['controlValue']! as Map,
    );
    expect(controlValue['role'], 'slider');
    expect((controlValue['value'] as Map)['value'], isA<num>());
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
    final settledValue = _controlValueTransitionFrom(settled)!;
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

  testWidgets('free-text dropdown values stay visible in session json', (
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
    expect(json, contains('Visible Secret City Name'));
    expect(json, contains('alpha-code'));
  });

  test('semantic properties retain raw value and label strings', () {
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
    expect(snapshot?.value?.kind, 'string');
    expect(snapshot?.value?.value, '15');
    expect(snapshot?.semanticValue?.kind, 'string');
    expect(snapshot?.semanticValue?.value, '15');
    expect(snapshot?.semanticLabel?.value, 'Duration fifteen seconds');
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
                    identifier: 'tugboat:duration-15',
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
                    identifier: 'tugboat:duration-30',
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
    expect((tapValue['semanticValue'] as Map)['value'], '30');
    expect((tapValue['value'] as Map)['value'], '30');
    expect((tapValue['semanticLabel'] as Map)['value'], 'Duration 30 seconds');
    expect(tapValue.toString(), contains('Duration 30 seconds'));

    final annotation = _semanticAnnotationFrom(tap)!;
    expect(
      annotation['schemaVersion'],
      tugboatSemanticAnnotationSchemaVersion,
    );
    expect(annotation['role'], 'button');
    expect((annotation['identifier'] as Map)['value'], 'duration-30');
    expect((annotation['value'] as Map)['value'], '30');
    expect((annotation['label'] as Map)['value'], 'Duration 30 seconds');
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

  testWidgets('rapid taps retain per-interaction after values', (tester) async {
    var enabled = false;
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => TugboatReplay.wrapApp(
          config: const TugboatReplayConfig(
            profile: TugboatCaptureProfile.exploration,
            settleDelay: Duration(milliseconds: 120),
            interactionClaimWindow: Duration.zero,
            enableGlobalPointerCapture: false,
            capturePixelRatio: 1.0,
          ),
          child: child!,
        ),
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) {
              return Switch(
                key: const Key('rapid-switch'),
                value: enabled,
                onChanged: (next) => setState(() => enabled = next),
              );
            },
          ),
        ),
      ),
    );
    await _waitForCaptures(tester);

    await tester.tap(find.byKey(const Key('rapid-switch')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('rapid-switch')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 150));
    for (var i = 0; i < 3; i += 1) {
      await _waitForCaptures(tester);
    }

    final session = TugboatReplay.controller!.session!;
    final taps = session.events.where((event) => event.type == 'tap').toList();
    final settles = session.events
        .where((event) => event.type == 'tap_settled')
        .toList();
    expect(taps, hasLength(2));
    expect(settles, hasLength(2));

    final first = _controlValueTransitionFrom(
      settles.firstWhere((event) => event.relatedEventId == taps[0].id),
    )!;
    final second = _controlValueTransitionFrom(
      settles.firstWhere((event) => event.relatedEventId == taps[1].id),
    )!;

    expect(((first['before'] as Map)['value'] as Map)['value'], isFalse);
    expect(((first['after'] as Map)['value'] as Map)['value'], isTrue);
    expect(((second['before'] as Map)['value'] as Map)['value'], isTrue);
    expect(((second['after'] as Map)['value'] as Map)['value'], isFalse);
  });

  testWidgets('same-frame taps omit ambiguous after values', (tester) async {
    var enabled = false;
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) =>
            TugboatReplay.wrapApp(config: _testConfig, child: child!),
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) {
              return Switch(
                key: const Key('same-frame-switch'),
                value: enabled,
                onChanged: (next) => setState(() => enabled = next),
              );
            },
          ),
        ),
      ),
    );
    await _waitForCaptures(tester);

    await tester.tap(find.byKey(const Key('same-frame-switch')));
    await tester.tap(find.byKey(const Key('same-frame-switch')));
    await tester.pump();
    for (var i = 0; i < 3; i += 1) {
      await _waitForCaptures(tester);
    }

    final session = TugboatReplay.controller!.session!;
    final settles = session.events
        .where((event) => event.type == 'tap_settled')
        .toList();
    expect(settles, hasLength(2));
    for (final settled in settles) {
      final transition = _controlValueTransitionFrom(settled)!;
      expect(transition, contains('before'));
      expect(transition, isNot(contains('after')));
    }
  });

  testWidgets('semantics-only controls are resampled without accessibility', (
    tester,
  ) async {
    const renderKey = GlobalObjectKey('semantics-only-control');
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => TugboatReplay.wrapApp(
          config: const TugboatReplayConfig(
            profile: TugboatCaptureProfile.productionLean,
            settleDelay: Duration.zero,
            interactionClaimWindow: Duration.zero,
            enableGlobalPointerCapture: false,
            capturePixelRatio: 1.0,
          ),
          child: child!,
        ),
        home: Scaffold(
          body: GestureDetector(
            onTap: () {
              final renderObject = renderKey.currentContext!.findRenderObject();
              (renderObject! as _SemanticsOnlyRenderBox).value = 'on';
            },
            child: const _SemanticsOnlyControl(key: renderKey, value: 'off'),
          ),
        ),
      ),
    );
    await _waitForCaptures(tester);

    await tester.tap(find.byKey(renderKey));
    await _waitForCaptures(tester);

    final settled = TugboatReplay.controller!.session!.events.firstWhere(
      (event) => event.type == 'tap_settled',
    );
    final transition = _controlValueTransitionFrom(settled)!;
    expect(((transition['before'] as Map)['value'] as Map)['value'], 'off');
    expect(((transition['after'] as Map)['value'] as Map)['value'], 'on');
    expect(
      ((transition['after'] as Map)['value'] as Map)['value'],
      isNot(((transition['before'] as Map)['value'] as Map)['value']),
    );
  });

  testWidgets('settle never borrows a replacement at the old coordinate', (
    tester,
  ) async {
    var showOriginal = true;
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) =>
            TugboatReplay.wrapApp(config: _testConfig, child: child!),
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) {
              if (showOriginal) {
                return Semantics(
                  identifier: 'tugboat:original-switch',
                  child: Switch(
                    key: const Key('original-switch'),
                    value: false,
                    onChanged: (_) => setState(() => showOriginal = false),
                  ),
                );
              }
              return Semantics(
                identifier: 'tugboat:replacement-switch',
                child: const Switch(
                  key: Key('replacement-switch'),
                  value: true,
                  onChanged: null,
                ),
              );
            },
          ),
        ),
      ),
    );
    await _waitForCaptures(tester);

    await tester.tap(find.byKey(const Key('original-switch')));
    await _waitForCaptures(tester);

    final settled = TugboatReplay.controller!.session!.events.firstWhere(
      (event) => event.type == 'tap_settled',
    );
    final transition = _controlValueTransitionFrom(settled)!;
    final annotation = _semanticAnnotationFrom(settled)!;

    expect(((transition['before'] as Map)['value'] as Map)['value'], isFalse);
    expect(transition, isNot(contains('after')));
    expect((annotation['identifier'] as Map)['value'], 'original-switch');
    expect(
      (annotation['identifier'] as Map)['value'],
      isNot('replacement-switch'),
    );
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
            identifier: 'tugboat:preset-list',
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
    final start = scrollEvents.firstWhere(
      (event) => event.type == 'scroll_start',
    );
    final end = scrollEvents.firstWhere((event) => event.type == 'scroll_end');
    for (final event in [start, end]) {
      final annotation = _semanticAnnotationFrom(event);
      expect(annotation, isNotNull);
      expect((annotation?['identifier'] as Map)['value'], 'preset-list');
    }
  });
}
