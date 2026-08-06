import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tugboat/tugboat.dart';

/// End-to-end verification of scroll playground interactions with event dump.
void main() {
  const config = TugboatReplayConfig(
    profile: TugboatCaptureProfile.exploration,
    interactionPublishMode: TugboatInteractionPublishMode.dualWrite,
    settleDelay: Duration.zero,
    interactionClaimWindow: Duration.zero,
    enableGlobalPointerCapture: false,
    scrollCaptureInterval: Duration(milliseconds: 50),
    captureScrollSamples: true,
    capturePixelRatio: 1.0,
  );

  Future<void> settle(WidgetTester tester) async {
    await tester.pump();
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 450));
    });
    await tester.pump();
  }

  testWidgets('scroll playground live verification dump', (tester) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) =>
            TugboatReplay.wrapApp(config: config, child: child!),
        home: Scaffold(
          body: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              TugboatSubView(
                label: 'vertical-feed',
                child: SizedBox(
                  height: 220,
                  key: const Key('vertical-feed'),
                  child: ListView.builder(
                    itemCount: 30,
                    itemBuilder: (context, index) =>
                        ListTile(title: Text('Feed row $index')),
                  ),
                ),
              ),
              TugboatSubView(
                label: 'carousel',
                child: SizedBox(
                  height: 120,
                  key: const Key('carousel'),
                  child: ListView.builder(
                    scrollDirection: Axis.horizontal,
                    itemCount: 12,
                    itemBuilder: (context, index) => Container(
                      width: 140,
                      margin: const EdgeInsets.only(right: 8),
                      color: Colors.primaries[index % Colors.primaries.length],
                    ),
                  ),
                ),
              ),
              TugboatSubView(
                label: 'hero-image',
                child: Container(
                  key: const Key('hero-image'),
                  height: 180,
                  color: Colors.blueGrey.shade200,
                ),
              ),
              SizedBox(
                height: 180,
                child: PageView(
                  key: const Key('page-view'),
                  children: const [
                    ColoredBox(color: Colors.red),
                    ColoredBox(color: Colors.green),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );

    await settle(tester);

    // Vertical feed scroll
    await tester.drag(
      find.byKey(const Key('vertical-feed')),
      const Offset(0, -160),
    );
    await settle(tester);

    // Horizontal carousel scroll
    await tester.drag(find.byKey(const Key('carousel')), const Offset(-140, 0));
    await settle(tester);

    // Dead swipe on static block
    await tester.drag(
      find.byKey(const Key('hero-image')),
      const Offset(0, -120),
    );
    await settle(tester);

    // PageView swipe
    await tester.drag(
      find.byKey(const Key('page-view')),
      const Offset(-260, 0),
    );
    await settle(tester);

    final session = TugboatReplay.controller!.session!;
    final interesting = session.events
        .where(
          (e) =>
              e.type == 'scroll_start' ||
              e.type == 'scroll_end' ||
              e.type == 'swipe',
        )
        .map(
          (e) => {
            'type': e.type,
            'id': e.id,
            if (e.relatedEventId != null) 'relatedEventId': e.relatedEventId,
            if (e.targetAnchor?.role != null) 'role': e.targetAnchor!.role,
            if (e.targetAnchor?.canonicalPath != null)
              'path': e.targetAnchor!.canonicalPath,
            'data': e.data,
          },
        )
        .toList();

    // ignore: avoid_print
    print('\n=== SCROLL PLAYGROUND LIVE VERIFICATION ===');
    // ignore: avoid_print
    print(const JsonEncoder.withIndent('  ').convert(interesting));

    expect(
      interesting.where((e) => e['type'] == 'scroll_start').length,
      greaterThanOrEqualTo(2),
    );
    expect(interesting.where((e) => e['type'] == 'swipe'), isNotEmpty);

    // Hero-image drag is inside the outer ListView: parent scroll fires with
    // overscroll but no offset change — failed scroll intent on static content.
    final overscrollAtStatic = interesting.where(
      (e) =>
          e['type'] == 'scroll_end' &&
          (e['data'] as Map)['overscrollCount'] != null &&
          ((e['data'] as Map)['overscrollCount'] as num) > 0,
    );
    expect(overscrollAtStatic, isNotEmpty);

    final verticalScroll = interesting.firstWhere(
      (e) =>
          e['type'] == 'scroll_start' &&
          (e['data'] as Map)['sectionLabel'] == 'vertical-feed',
    );
    expect(verticalScroll['role'], 'scrollable');
  });
}
