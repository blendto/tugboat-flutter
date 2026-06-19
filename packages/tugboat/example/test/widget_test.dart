import 'package:tugboat_example/main.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('demo app loads home screen', (tester) async {
    await tester.pumpWidget(const ReplayDemoApp());
    await tester.pump();
    expect(find.text('Tugboat Replay Demo'), findsOneWidget);
    expect(find.text('Explore every screen'), findsOneWidget);
    expect(find.text('Product catalog'), findsOneWidget);
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 300));
    }
  });
}
