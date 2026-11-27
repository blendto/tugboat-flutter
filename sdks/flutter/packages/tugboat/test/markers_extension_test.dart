import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tugboat/src/anchors.dart';
import 'package:tugboat/tugboat.dart';

void main() {
  test('tugboatTag wraps the receiver in TugboatTag', () {
    final child = Text('Pay');
    final wrapped = child.tugboatTag('checkout');

    expect(wrapped, isA<TugboatTag>());
    expect((wrapped as TugboatTag).id, 'checkout');
    expect(wrapped.child, same(child));
  });

  test('tugboatSensitive wraps the receiver in TugboatSensitive', () {
    final child = Text('Card number');
    final wrapped = child.tugboatSensitive();

    expect(wrapped, isA<TugboatSensitive>());
    expect((wrapped as TugboatSensitive).child, same(child));
  });

  test('tugboatSubView wraps the receiver in TugboatSubView', () {
    final child = Text('Shipping');
    final wrapped = child.tugboatSubView('step');

    expect(wrapped, isA<TugboatSubView>());
    expect((wrapped as TugboatSubView).label, 'step');
    expect(wrapped.child, same(child));
  });

  testWidgets('tugboatSensitive masks the same rects as TugboatSensitive', (
    tester,
  ) async {
    final rootKey = GlobalKey();

    Future<List<Rect>> masksFor(Widget marked) async {
      await tester.pumpWidget(
        MaterialApp(
          home: RepaintBoundary(
            key: rootKey,
            child: Scaffold(body: Center(child: marked)),
          ),
        ),
      );
      await tester.pump();
      final resolver = AnchorResolver(rootKey: rootKey);
      return resolver.collectMaskRects(
        rootRender: rootKey.currentContext!.findRenderObject()! as RenderBox,
        shouldMask: (element, widget, renderObject, explicitlySensitive, _) =>
            explicitlySensitive,
      );
    }

    const panel = SizedBox(
      width: 80,
      height: 40,
      child: ColoredBox(color: Colors.black),
    );
    final wrapper = await masksFor(TugboatSensitive(child: panel));
    final extension = await masksFor(panel.tugboatSensitive());

    expect(wrapper, isNotEmpty);
    expect(extension, wrapper);
  });

  testWidgets('tugboatSubView contributes its label like TugboatSubView', (
    tester,
  ) async {
    final rootKey = GlobalKey();

    Future<String?> subViewLabel(Widget body) async {
      await tester.pumpWidget(
        MaterialApp(
          home: RepaintBoundary(
            key: rootKey,
            child: Scaffold(body: Center(child: body)),
          ),
        ),
      );
      await tester.pump();
      return AnchorResolver(
        rootKey: rootKey,
      ).subViewLabelFor(tester.element(find.text('Step body')));
    }

    final wrapper = await subViewLabel(
      TugboatSubView(label: 'step', child: const Text('Step body')),
    );
    final extension = await subViewLabel(
      const Text('Step body').tugboatSubView('step'),
    );

    expect(wrapper, 'step');
    expect(extension, wrapper);
  });
}
