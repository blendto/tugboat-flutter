import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tugboat/tugboat.dart';

import 'helpers/widget_capture_wait.dart';

// Fixtures shaped like the Blend app (mobile_app): the MaterialApp builder
// wraps the Navigator in an app widget that inserts a persistent entry into
// the root overlay (PendingOperationsRootOverlayHost), a MediaQuery copy, and
// a Material 2 theme. A real device run named none of its sheets or dialogs.

TugboatReplayConfig _config({required bool exploration}) => TugboatReplayConfig(
  enabled: true,
  emitSceneInventory: exploration,
  screenshotMaskLevel: TugboatScreenshotMaskLevel.explicitOnly,
  settleDelay: Duration.zero,
  interactionClaimWindow: Duration.zero,
  capturePixelRatio: 1.0,
);

final _navigatorKey = GlobalKey<NavigatorState>();

/// Public app widget between the capture root and the Navigator. It keeps one
/// entry of its own on top of the root overlay, empty while idle.
class RootOverlayHost extends StatefulWidget {
  const RootOverlayHost({super.key, required this.child});
  final Widget child;
  @override
  State<RootOverlayHost> createState() => _RootOverlayHostState();
}

class _RootOverlayHostState extends State<RootOverlayHost> {
  OverlayEntry? _entry;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _insert());
  }

  void _insert() {
    final overlay = _navigatorKey.currentState?.overlay;
    if (overlay == null || _entry != null) return;
    _entry = OverlayEntry(builder: (_) => const SizedBox.shrink());
    overlay.insert(_entry!);
  }

  @override
  void dispose() {
    _entry?.remove();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// Named sheet: `/changeLanguage` with a stateful class (LanguageSelectionModal).
class LanguageSheet extends StatefulWidget {
  const LanguageSheet({super.key});
  @override
  State<LanguageSheet> createState() => _LanguageSheetState();
}

class _LanguageSheetState extends State<LanguageSheet> {
  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      Row(
        children: [
          const Text('Choose'),
          InkWell(onTap: () {}, child: const Icon(Icons.close)),
        ],
      ),
      SizedBox(
        height: 160,
        child: ListView(
          children: [
            for (var i = 0; i < 3; i++)
              InkWell(onTap: () {}, child: Text('Language $i')),
          ],
        ),
      ),
      TextButton(onPressed: () {}, child: const Text('Save')),
    ],
  );
}

/// Public content wrapper the app's sheets share (BottomSheetContent).
class SheetContent extends StatelessWidget {
  const SheetContent({super.key, required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    children: [const Text('Title'), child],
  );
}

/// Anonymous sheet whose builder returns the widget itself
/// (SuggestionFeaturesBottomsheet).
class FeaturesSheet extends StatefulWidget {
  const FeaturesSheet({super.key});

  Future<int?> open(BuildContext context) => showModalBottomSheet<int>(
    context: context,
    useSafeArea: true,
    isScrollControlled: true,
    builder: (context) => this,
  );

  @override
  State<FeaturesSheet> createState() => _FeaturesSheetState();
}

class _FeaturesSheetState extends State<FeaturesSheet> {
  @override
  Widget build(BuildContext context) => SheetContent(
    child: SafeArea(
      child: Row(
        children: [
          for (var i = 0; i < 2; i++)
            GestureDetector(
              onTap: () {},
              child: SizedBox(width: 80, height: 40, child: Text('Tool $i')),
            ),
        ],
      ),
    ),
  );
}

/// `showDialog(builder: (_) => Dialog.fullscreen(child: CouponDialog()))`.
class CouponDialog extends StatelessWidget {
  const CouponDialog({super.key});

  static void open(BuildContext context) => showDialog<void>(
    context: context,
    useRootNavigator: true,
    useSafeArea: false,
    barrierColor: Colors.black.withValues(alpha: 0.4),
    builder: (context) => Dialog.fullscreen(
      backgroundColor: Colors.black.withValues(alpha: 0.8),
      child: const CouponDialog(),
    ),
  );

  @override
  Widget build(BuildContext context) => Stack(
    children: [
      Positioned(
        top: 40,
        right: 20,
        child: GestureDetector(
          onTap: () => Navigator.of(context).pop(),
          child: const Icon(Icons.close),
        ),
      ),
      Center(
        child: InkWell(onTap: () {}, child: const Text('Continue offer')),
      ),
    ],
  );
}

/// A named `PopupRoute` that wraps the app's paywall in its own Scaffold
/// (`_PaywallBottomSheetRoute`).
class _PaywallRoute<T> extends PopupRoute<T> {
  _PaywallRoute({required this.builder, required super.settings});

  final WidgetBuilder builder;

  @override
  Duration get transitionDuration => const Duration(milliseconds: 300);
  @override
  Color get barrierColor => Colors.black.withValues(alpha: 0.8);
  @override
  bool get barrierDismissible => false;
  @override
  String get barrierLabel => 'Dismiss';

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) => Scaffold(backgroundColor: Colors.transparent, body: builder(context));

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) => FadeTransition(
    opacity: animation,
    child: Theme(data: ThemeData(useMaterial3: false), child: child),
  );
}

class SubscriptionPaywall extends StatelessWidget {
  const SubscriptionPaywall({super.key});
  @override
  Widget build(BuildContext context) => Column(
    children: [
      OutlinedButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('Close paywall'),
      ),
      GestureDetector(onTap: () {}, child: const Text('Monthly')),
    ],
  );
}

class CouponPaywall extends StatelessWidget {
  const CouponPaywall({super.key});
  @override
  Widget build(BuildContext context) => Column(
    children: [
      OutlinedButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('Close coupon'),
      ),
    ],
  );
}

class PlainSheetBody extends StatelessWidget {
  const PlainSheetBody({super.key});
  @override
  Widget build(BuildContext context) =>
      FilledButton(onPressed: () {}, child: const Text('Plain'));
}

typedef _Opener = void Function(BuildContext context);

Future<void> _mountHostApp(
  WidgetTester tester,
  _Opener opener, {
  required bool exploration,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      navigatorKey: _navigatorKey,
      theme: ThemeData(useMaterial3: false),
      navigatorObservers: [TugboatReplay.navigatorObserver],
      builder: (context, child) => TugboatReplay.wrapApp(
        config: _config(exploration: exploration),
        child: RootOverlayHost(
          child: MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.noScaling),
            child: child!,
          ),
        ),
      ),
      initialRoute: '/home',
      routes: {
        '/home': (context) => Scaffold(
          body: Center(
            child: Builder(
              builder: (context) => FilledButton(
                onPressed: () => opener(context),
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      },
    ),
  );
  await waitForTugboatCaptureWork(tester);
}

Future<void> _settle(WidgetTester tester) async {
  await tester.pumpAndSettle();
  await waitForTugboatCaptureWork(tester);
}

List<Map<String, Object?>> _inventories() => [
  for (final event in TugboatReplay.controller!.session!.events)
    if (event.type == 'scene_inventory') event.data,
];

List<Map<String, Object?>> _taps() => [
  for (final event in TugboatReplay.controller!.session!.events)
    if (event.type == 'interaction' && event.data['gesture'] == 'tap')
      event.data,
];

Map<String, Object?> _surface(Map<String, Object?> inventory) =>
    (inventory['surface']! as Map).cast<String, Object?>();

/// Opens the overlay and returns the newest inventory that is not the home
/// page's.
Future<Map<String, Object?>> _openInExploration(
  WidgetTester tester,
  _Opener opener,
) async {
  await _mountHostApp(tester, opener, exploration: true);
  await tester.tap(find.text('Open'));
  await _settle(tester);
  return _inventories().lastWhere((i) => i['routeKey'] != '/home');
}

Map<String, Object?> _entryFor(Map<String, Object?> inventory, String tail) =>
    (inventory['elements']! as List).cast<Map<String, Object?>>().firstWhere(
      (e) => (e['canonicalPath']! as String).endsWith(tail),
    );

/// Taps [label] on the opened overlay in one mode and returns the tap event.
Future<Map<String, Object?>> _tapIn(
  WidgetTester tester,
  _Opener opener,
  String label, {
  required bool exploration,
}) async {
  await tester.pumpWidget(const SizedBox());
  TugboatReplay.resetForTest();
  await _mountHostApp(tester, opener, exploration: exploration);
  await tester.tap(find.text('Open'));
  await _settle(tester);
  await tester.tap(find.text(label));
  await _settle(tester);
  return _taps().last;
}

void main() {
  tearDown(TugboatReplay.resetForTest);

  testWidgets('a named sheet under an app wrapper is named', (tester) async {
    final inventory = await _openInExploration(
      tester,
      (c) => showModalBottomSheet<void>(
        context: c,
        routeSettings: const RouteSettings(name: '/changeLanguage'),
        isScrollControlled: true,
        builder: (_) => const LanguageSheet(),
      ),
    );

    expect(inventory['routeKey'], '/changeLanguage');
    expect(_surface(inventory), {
      'kind': 'sheet',
      'widgetClass': 'LanguageSheet',
    });
  });

  testWidgets('an anonymous sheet under an app wrapper gets its class key, '
      'and both tap modes agree with the inventory', (tester) async {
    void opener(BuildContext c) => const FeaturesSheet().open(c);
    final inventory = await _openInExploration(tester, opener);

    expect(inventory['routeKey'], 'sheet:FeaturesSheet');
    expect(_surface(inventory), {
      'kind': 'sheet',
      'widgetClass': 'FeaturesSheet',
    });
    final entry = _entryFor(inventory, 'GestureDetector#0');
    expect(
      entry['canonicalPath'],
      'DisplayFeatureSubScreen/BottomSheet#0/RawGestureDetector#0/'
      'FeaturesSheet#0/SheetContent#0/GestureDetector#0',
    );
    // Schema 6 fingerprint of the same control, observed on main (0.10.11).
    expect(entry['aliases'], contains(_schema6FeaturesTool0));

    final exploration = await _tapIn(
      tester,
      opener,
      'Tool 0',
      exploration: true,
    );
    final production = await _tapIn(
      tester,
      opener,
      'Tool 0',
      exploration: false,
    );
    expect(exploration['routeKey'], 'sheet:FeaturesSheet');
    expect(exploration['targetFingerprint'], entry['fingerprint']);
    expect(production['targetFingerprint'], entry['fingerprint']);
    expect(production.containsKey('routeKey'), isFalse);
  });

  testWidgets('a full-screen Dialog around an app class names the class', (
    tester,
  ) async {
    final inventory = await _openInExploration(tester, CouponDialog.open);

    expect(inventory['routeKey'], 'dialog:CouponDialog');
    expect(_surface(inventory), {
      'kind': 'dialog',
      'widgetClass': 'CouponDialog',
    });
    final entry = _entryFor(inventory, 'InkWell#0/GestureDetector#0');
    expect(
      entry['canonicalPath'],
      'DisplayFeatureSubScreen/Dialog#0/CouponDialog#0/InkWell#0/'
      'GestureDetector#0',
    );
    expect(entry['aliases'], contains(_schema6CouponContinue));

    final exploration = await _tapIn(
      tester,
      CouponDialog.open,
      'Continue offer',
      exploration: true,
    );
    final production = await _tapIn(
      tester,
      CouponDialog.open,
      'Continue offer',
      exploration: false,
    );
    expect(exploration['routeKey'], 'dialog:CouponDialog');
    expect(exploration['targetFingerprint'], entry['fingerprint']);
    expect(production['targetFingerprint'], entry['fingerprint']);
  });

  testWidgets('a named popup that wraps two paywalls in its own Scaffold '
      'keeps its name and reports each class', (tester) async {
    _Opener paywall(WidgetBuilder builder) =>
        (c) => Navigator.of(c).push(
          _PaywallRoute<void>(
            builder: builder,
            settings: const RouteSettings(name: '/subscriptionPaywall'),
          ),
        );

    final subscription = await _openInExploration(
      tester,
      paywall((_) => const SubscriptionPaywall()),
    );
    await tester.pumpWidget(const SizedBox());
    TugboatReplay.resetForTest();
    final coupon = await _openInExploration(
      tester,
      paywall((_) => const CouponPaywall()),
    );

    expect(subscription['routeKey'], '/subscriptionPaywall');
    expect(coupon['routeKey'], '/subscriptionPaywall');
    expect(_surface(subscription), {
      'kind': 'popup',
      'widgetClass': 'SubscriptionPaywall',
    });
    expect(_surface(coupon), {'kind': 'popup', 'widgetClass': 'CouponPaywall'});
  });

  testWidgets(
    'a sheet whose builder returns a Scaffold is not looked through',
    (tester) async {
      final inventory = await _openInExploration(
        tester,
        (c) => showModalBottomSheet<void>(
          context: c,
          builder: (_) => const Scaffold(body: PlainSheetBody()),
        ),
      );

      expect(inventory['routeKey'], 'ModalBottomSheetRoute<void>');
      expect(_surface(inventory), {'kind': 'sheet'});
    },
  );

  testWidgets('a Dialog with several retained children names nothing', (
    tester,
  ) async {
    final inventory = await _openInExploration(
      tester,
      (c) => showDialog<void>(
        context: c,
        builder: (_) => Dialog(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const PlainSheetBody(),
              TextButton(onPressed: () {}, child: const Text('Other')),
            ],
          ),
        ),
      ),
    );

    expect(_surface(inventory), {'kind': 'dialog'});
    expect((inventory['routeKey']! as String).startsWith('struct:'), isTrue);
  });
}

// Observed on origin/main (0.10.11, schema 6) with this same fixture.
const _schema6FeaturesTool0 = 'b56e0daf92657521';
const _schema6CouponContinue = '1fd14082461a571d';
