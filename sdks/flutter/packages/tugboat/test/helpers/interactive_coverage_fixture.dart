import 'package:flutter/cupertino.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:tugboat/tugboat.dart';

/// One widget per interactive pattern, each under a `cov-*` key, for
/// `test/interactive_coverage_test.dart`. The test asserts which patterns the
/// scene inventory reports and why the others are not. Nothing here shows
/// user content: labels are fixed strings.
class InteractiveCoverageScreen extends StatelessWidget {
  const InteractiveCoverageScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final pattern in _patterns)
              KeyedBox(pattern.key, pattern.child),
          ],
        ),
      ),
    );
  }
}

/// A fixed-size box with a key the coverage test can find.
class KeyedBox extends StatelessWidget {
  const KeyedBox(this.keyName, this.child, {super.key});

  final String keyName;
  final Widget child;

  @override
  Widget build(BuildContext context) =>
      SizedBox(key: Key(keyName), height: 64, width: 160, child: child);
}

class _Pattern {
  const _Pattern(this.key, this.child);
  final String key;
  final Widget child;
}

final _patterns = <_Pattern>[
  // Material buttons and tiles.
  _Pattern(
    'cov-filled',
    FilledButton(onPressed: () {}, child: const Text('A')),
  ),
  _Pattern(
    'cov-filled-disabled',
    FilledButton(onPressed: null, child: const Text('B')),
  ),
  _Pattern(
    'cov-icon',
    IconButton(onPressed: () {}, icon: const Icon(Icons.add)),
  ),
  _Pattern(
    'cov-icon-disabled',
    IconButton(onPressed: null, icon: const Icon(Icons.remove)),
  ),
  _Pattern('cov-list-tile', ListTile(onTap: () {}, title: const Text('C'))),
  _Pattern('cov-list-tile-passive', ListTile(title: const Text('D'))),
  _Pattern('cov-checkbox', Checkbox(value: false, onChanged: (_) {})),
  _Pattern('cov-switch', Switch(value: false, onChanged: (_) {})),
  _Pattern('cov-chip', ActionChip(label: const Text('E'), onPressed: () {})),
  _Pattern('cov-slider', Slider(value: 0.5, onChanged: (_) {})),
  _Pattern('cov-text-field', const TextField()),
  // Cupertino.
  _Pattern(
    'cov-cupertino',
    CupertinoButton(onPressed: () {}, child: const Text('F')),
  ),
  // Gesture primitives.
  _Pattern(
    'cov-ink-well',
    InkWell(
      onTap: () {},
      child: const Center(child: Text('G')),
    ),
  ),
  _Pattern(
    'cov-ink-well-disabled',
    InkWell(child: const Center(child: Text('H'))),
  ),
  _Pattern(
    'cov-gesture-tap',
    GestureDetector(
      onTap: () {},
      child: const Center(child: Text('I')),
    ),
  ),
  _Pattern(
    'cov-gesture-pan-only',
    GestureDetector(
      onVerticalDragUpdate: (_) {},
      child: const Center(child: Text('J')),
    ),
  ),
  _Pattern(
    'cov-semantics-tap',
    Semantics(
      onTap: () {},
      child: const Center(child: Text('K')),
    ),
  ),
  _Pattern(
    'cov-semantics-label-only',
    Semantics(
      label: 'L',
      child: const Center(child: Text('L')),
    ),
  ),
  _Pattern(
    'cov-listener-pointer-up',
    Listener(
      onPointerUp: (_) {},
      child: const Center(child: Text('M')),
    ),
  ),
  _Pattern(
    'cov-listener-pointer-down',
    Listener(
      onPointerDown: (_) {},
      child: const Center(child: Text('N')),
    ),
  ),
  _Pattern(
    'cov-raw-tap',
    RawGestureDetector(
      gestures: {
        TapGestureRecognizer:
            GestureRecognizerFactoryWithHandlers<TapGestureRecognizer>(
              TapGestureRecognizer.new,
              (recognizer) => recognizer.onTap = () {},
            ),
      },
      child: const Center(child: Text('O')),
    ),
  ),
  _Pattern(
    'cov-mouse-region',
    MouseRegion(
      onEnter: (_) {},
      child: const Center(child: Text('P')),
    ),
  ),
  _Pattern(
    'cov-mouse-over-button',
    MouseRegion(
      onEnter: (_) {},
      child: FilledButton(onPressed: () {}, child: const Text('Q')),
    ),
  ),
  // Stacked layers of one button: GestureDetector, InkWell and MouseRegion
  // at the same box must be one entry plus aliases.
  _Pattern(
    'cov-stacked',
    MouseRegion(
      onEnter: (_) {},
      child: GestureDetector(
        onTap: () {},
        child: InkWell(
          onTap: () {},
          child: const Center(child: Text('R')),
        ),
      ),
    ),
  ),
  _Pattern(
    'cov-tagged',
    TugboatTag(
      'checkout-cta',
      child: FilledButton(onPressed: () {}, child: const Text('S')),
    ),
  ),
];
