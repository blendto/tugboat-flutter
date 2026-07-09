import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tugboat/tugboat.dart';

const _scrollTestConfig = TugboatReplayConfig(
  profile: TugboatCaptureProfile.exploration,
  settleDelay: Duration.zero,
  enableGlobalPointerCapture: false,
  scrollCaptureInterval: Duration(milliseconds: 50),
  captureScrollSamples: true,
  capturePixelRatio: 1.0,
);

Future<void> _waitForCaptures(WidgetTester tester) async {
  await tester.pump();
  await tester.runAsync(() async {
    await Future<void>.delayed(const Duration(milliseconds: 400));
  });
  await tester.pump();
}

void main() {
  testWidgets('ListView scroll carries scrollable target anchor', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) =>
            TugboatReplay.wrapApp(config: _scrollTestConfig, child: child!),
        home: Scaffold(
          body: ListView.builder(
            itemCount: 40,
            itemBuilder: (context, index) =>
                ListTile(title: Text('Scroll item $index')),
          ),
        ),
      ),
    );

    await _waitForCaptures(tester);
    await tester.drag(find.byType(ListView), const Offset(0, -250));
    await _waitForCaptures(tester);

    final session = TugboatReplay.controller!.session!;
    final scrollStarts = session.events
        .where((event) => event.type == 'scroll_start')
        .toList();
    final scrollEnds = session.events
        .where((event) => event.type == 'scroll_end')
        .toList();

    expect(scrollStarts, isNotEmpty);
    expect(scrollEnds, isNotEmpty);
    expect(scrollStarts.first.targetAnchor, isNotNull);
    expect(scrollStarts.first.targetAnchor!.role, 'scrollable');
    expect(scrollStarts.first.targetAnchor!.canonicalPath, isNotEmpty);
    expect(scrollStarts.first.data['axis'], isNotNull);
    expect(scrollStarts.first.data['depth'], isNotNull);
    expect(scrollEnds.first.relatedEventId, scrollStarts.first.id);
    expect(
      scrollEnds.first.targetAnchor?.fingerprint,
      scrollStarts.first.targetAnchor?.fingerprint,
    );
  });

  testWidgets('dead swipe on static widget emits swipe without tap_settled', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) =>
            TugboatReplay.wrapApp(config: _scrollTestConfig, child: child!),
        home: const Scaffold(
          body: Center(
            child: SizedBox(
              key: Key('static-block'),
              width: 200,
              height: 200,
              child: ColoredBox(color: Colors.blue),
            ),
          ),
        ),
      ),
    );

    await _waitForCaptures(tester);
    await tester.drag(
      find.byKey(const Key('static-block')),
      const Offset(0, -120),
    );
    await _waitForCaptures(tester);

    final session = TugboatReplay.controller!.session!;
    final swipes = session.events
        .where((event) => event.type == 'swipe')
        .toList();
    final settled = session.events
        .where((event) => event.type == 'tap_settled')
        .toList();
    final scrollStarts = session.events
        .where((event) => event.type == 'scroll_start')
        .toList();

    expect(swipes, isNotEmpty);
    expect(swipes.first.data['scrolled'], isFalse);
    expect(swipes.first.result, TugboatInteractionResult.noVisibleChange);
    expect(swipes.first.relatedEventId, isNotNull);
    expect(settled, isEmpty);
    expect(scrollStarts, isEmpty);
  });

  testWidgets('scroll swipe links tap to scroll_start via swipe event', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) =>
            TugboatReplay.wrapApp(config: _scrollTestConfig, child: child!),
        home: Scaffold(
          body: ListView.builder(
            itemCount: 30,
            itemBuilder: (context, index) =>
                ListTile(title: Text('Linked scroll $index')),
          ),
        ),
      ),
    );

    await _waitForCaptures(tester);
    await tester.drag(find.byType(ListView), const Offset(0, -200));
    await _waitForCaptures(tester);

    final session = TugboatReplay.controller!.session!;
    final swipes = session.events
        .where((event) => event.type == 'swipe')
        .toList();
    final scrollStarts = session.events
        .where((event) => event.type == 'scroll_start')
        .toList();

    expect(swipes, isNotEmpty);
    expect(scrollStarts, isNotEmpty);
    expect(swipes.first.data['scrolled'], isTrue);
    expect(swipes.first.data['scrollStartEventId'], scrollStarts.first.id);
  });

  testWidgets('sub-slop tap still emits tap_settled', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) =>
            TugboatReplay.wrapApp(config: _scrollTestConfig, child: child!),
        home: Scaffold(
          body: FilledButton(onPressed: () {}, child: const Text('Tap me')),
        ),
      ),
    );

    await _waitForCaptures(tester);
    await tester.tap(find.text('Tap me'));
    await _waitForCaptures(tester);

    final session = TugboatReplay.controller!.session!;
    expect(session.events.where((event) => event.type == 'tap'), isNotEmpty);
    expect(
      session.events.where((event) => event.type == 'tap_settled'),
      isNotEmpty,
    );
    expect(session.events.where((event) => event.type == 'swipe'), isEmpty);
  });

  testWidgets('TugboatSubView label appears on scroll_start data', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) =>
            TugboatReplay.wrapApp(config: _scrollTestConfig, child: child!),
        home: Scaffold(
          body: TugboatSubView(
            label: 'feed-section',
            child: ListView.builder(
              itemCount: 25,
              itemBuilder: (context, index) =>
                  ListTile(title: Text('Section item $index')),
            ),
          ),
        ),
      ),
    );

    await _waitForCaptures(tester);
    await tester.drag(find.byType(ListView), const Offset(0, -180));
    await _waitForCaptures(tester);

    final scrollStart = TugboatReplay.controller!.session!.events.firstWhere(
      (event) => event.type == 'scroll_start',
    );
    expect(scrollStart.data['sectionLabel'], 'feed-section');
  });

  testWidgets('nested scrollables produce independent scroll pairs', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) =>
            TugboatReplay.wrapApp(config: _scrollTestConfig, child: child!),
        home: Scaffold(
          body: ListView(
            children: [
              SizedBox(
                height: 120,
                child: ListView.builder(
                  scrollDirection: Axis.horizontal,
                  itemCount: 8,
                  itemBuilder: (context, index) => Container(
                    width: 100,
                    margin: const EdgeInsets.all(4),
                    color: Colors.primaries[index % Colors.primaries.length],
                  ),
                ),
              ),
              for (var i = 0; i < 20; i++)
                ListTile(title: Text('Outer row $i')),
            ],
          ),
        ),
      ),
    );

    await _waitForCaptures(tester);
    final horizontalList = find.byWidgetPredicate(
      (widget) =>
          widget is ListView && widget.scrollDirection == Axis.horizontal,
    );
    final verticalList = find.byWidgetPredicate(
      (widget) => widget is ListView && widget.scrollDirection == Axis.vertical,
    );
    await tester.drag(horizontalList, const Offset(-120, 0));
    await _waitForCaptures(tester);
    await tester.drag(verticalList, const Offset(0, -180));
    await _waitForCaptures(tester);

    final session = TugboatReplay.controller!.session!;
    final scrollStarts = session.events
        .where((event) => event.type == 'scroll_start')
        .toList();
    final scrollEnds = session.events
        .where((event) => event.type == 'scroll_end')
        .toList();

    expect(scrollStarts.length, greaterThanOrEqualTo(2));
    expect(scrollEnds.length, greaterThanOrEqualTo(2));
    final axes = scrollStarts.map((event) => event.data['axis']).toSet();
    expect(axes, containsAll(['horizontal', 'vertical']));
  });

  testWidgets('PageView scroll emits page metrics', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) =>
            TugboatReplay.wrapApp(config: _scrollTestConfig, child: child!),
        home: Scaffold(
          body: PageView(
            children: const [
              ColoredBox(color: Colors.red),
              ColoredBox(color: Colors.green),
              ColoredBox(color: Colors.blue),
            ],
          ),
        ),
      ),
    );

    await _waitForCaptures(tester);
    await tester.drag(find.byType(PageView), const Offset(-300, 0));
    await _waitForCaptures(tester);

    final scrollStart = TugboatReplay.controller!.session!.events
        .where((event) => event.type == 'scroll_start')
        .toList();
    expect(scrollStart, isNotEmpty);
    expect(scrollStart.first.data.containsKey('page'), isTrue);
  });
}
