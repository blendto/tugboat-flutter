import 'package:build/build.dart';
import 'package:build_test/build_test.dart';
import 'package:pmkit_builder/pmkit_builder.dart';
import 'package:test/test.dart';

void main() {
  test('generates a deterministic catalog of public custom widgets', () async {
    final builder = pmkitWidgetCatalogBuilder(BuilderOptions.empty);
    await testBuilder(
      builder,
      {
        'flutter|lib/widgets.dart': '''
library flutter.widgets;

abstract class Widget { const Widget(); }
abstract class StatelessWidget extends Widget {
  const StatelessWidget();
  Widget build(Object context);
}
class SizedBox extends StatelessWidget {
  const SizedBox();
  @override
  Widget build(Object context) => this;
}
''',
        'example|lib/example.dart': '''
import 'package:flutter/widgets.dart';

class CheckoutButton extends StatelessWidget {
  const CheckoutButton();
  @override
  Widget build(Object context) => const SizedBox();
}

class _PrivateCard extends StatelessWidget {
  const _PrivateCard();
  @override
  Widget build(Object context) => const SizedBox();
}
''',
      },
      outputs: {
        'flutter|lib/pmkit_widgets.g.dart': anything,
        'example|lib/pmkit_widgets.g.dart': decodedMatches(
          allOf(
            contains("CheckoutButton: 'CheckoutButton'"),
            isNot(contains('_PrivateCard')),
            isNot(contains("SizedBox: 'SizedBox'")),
          ),
        ),
      },
    );
  });
}
