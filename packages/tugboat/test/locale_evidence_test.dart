import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tugboat/tugboat.dart';

void main() {
  setUp(() {
    TugboatReplay.debugConfigureControllerForTest = (controller) {
      controller.debugExecuteCapture =
          ({required trigger, required force}) async =>
              controller.debugSeedFrame(trigger: trigger);
    };
  });
  tearDown(TugboatReplay.resetForTest);

  testWidgets('session, locale changes, and interactions carry app locale', (
    tester,
  ) async {
    final appLocale = ValueNotifier(const Locale('en', 'US'));
    addTearDown(appLocale.dispose);
    const config = TugboatReplayConfig(
      profile: TugboatCaptureProfile.exploration,
      settleDelay: Duration.zero,
      interactionClaimWindow: Duration.zero,
      enableGlobalPointerCapture: false,
      capturePixelRatio: 1,
    );

    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => ValueListenableBuilder<Locale>(
          valueListenable: appLocale,
          builder: (context, locale, _) => Localizations.override(
            context: context,
            locale: locale,
            child: TugboatReplay.wrapApp(config: config, child: child!),
          ),
        ),
        home: Scaffold(
          body: FilledButton(onPressed: () {}, child: const Text('Continue')),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    final controller = TugboatReplay.controller!;
    expect(controller.session?.locale?.tag, 'en-US');
    expect(
      controller.session?.events.where(
        (event) => event.type == 'locale_changed',
      ),
      isEmpty,
    );

    appLocale.value = const Locale('es', 'ES');
    await tester.pump();
    await tester.pump();

    final localeChange = controller.session!.events.singleWhere(
      (event) => event.type == 'locale_changed',
    );
    expect(localeChange.stream, TugboatEventStream.evidence);
    expect(localeChange.locale?.tag, 'es-ES');
    expect((localeChange.data['previousLocale'] as Map)['tag'], 'en-US');
    expect((localeChange.data['locale'] as Map)['tag'], 'es-ES');

    final tapPosition = tester.getCenter(find.text('Continue'));
    controller.recordPointerDown(tapPosition);
    controller.recordPointerUp(tapPosition);
    await tester.pump(const Duration(milliseconds: 350));

    final interaction = controller.session!.events.singleWhere(
      (event) => event.type == 'interaction',
    );
    expect(interaction.locale?.tag, 'es-ES');
  });

  testWidgets('setLocale covers apps outside Localizations', (tester) async {
    const config = TugboatReplayConfig(
      profile: TugboatCaptureProfile.productionLean,
      settleDelay: Duration.zero,
      enableGlobalPointerCapture: false,
    );
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) =>
            TugboatReplay.wrapApp(config: config, child: child!),
        home: const SizedBox.expand(),
      ),
    );
    await tester.pump();
    await tester.pump();

    TugboatReplay.setLocale(const Locale('fr', 'CA'));

    final change = TugboatReplay.controller!.session!.events.singleWhere(
      (event) => event.type == 'locale_changed',
    );
    expect(change.locale?.tag, 'fr-CA');
    expect(TugboatReplay.controller!.session!.locale?.tag, 'fr-CA');
  });

  testWidgets('interaction keeps the locale visible at pointer down', (
    tester,
  ) async {
    final appLocale = ValueNotifier(const Locale('en', 'US'));
    addTearDown(appLocale.dispose);
    const config = TugboatReplayConfig(
      profile: TugboatCaptureProfile.exploration,
      settleDelay: Duration.zero,
      interactionClaimWindow: Duration.zero,
      enableGlobalPointerCapture: false,
      capturePixelRatio: 1,
    );

    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => ValueListenableBuilder<Locale>(
          valueListenable: appLocale,
          builder: (context, locale, _) => Localizations.override(
            context: context,
            locale: locale,
            child: TugboatReplay.wrapApp(config: config, child: child!),
          ),
        ),
        home: const Scaffold(body: SizedBox.expand()),
      ),
    );
    await tester.pump();
    await tester.pump();

    final controller = TugboatReplay.controller!;
    const position = Offset(50, 50);
    controller.recordPointerDown(position);
    controller.recordPointerUp(position);
    appLocale.value = const Locale('es', 'ES');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));

    final interaction = controller.session!.events.singleWhere(
      (event) => event.type == 'interaction',
    );
    expect(interaction.locale?.tag, 'en-US');
    expect(controller.session?.locale?.tag, 'es-ES');
  });
}
