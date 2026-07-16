import 'package:flutter_test/flutter_test.dart';
import 'package:tugboat/tugboat.dart';

void main() {
  test('resolveViewportSemanticPolicy covers profile × mode matrix', () {
    expect(
      resolveViewportSemanticPolicy(
        profile: TugboatCaptureProfile.dormant,
        mode: TugboatViewportSemanticMode.full,
      ),
      TugboatViewportSemanticPolicy.off,
    );

    final explorationFull = resolveViewportSemanticPolicy(
      profile: TugboatCaptureProfile.exploration,
      mode: TugboatViewportSemanticMode.full,
    );
    expect(explorationFull.engineEnabled, isTrue);
    expect(explorationFull.emitEvents, isTrue);
    expect(explorationFull.debugLogs, isFalse);
    expect(explorationFull.holdPersistentSemanticsHandle, isTrue);

    final explorationDebug = resolveViewportSemanticPolicy(
      profile: TugboatCaptureProfile.exploration,
      mode: TugboatViewportSemanticMode.fullWithDebugLogs,
    );
    expect(explorationDebug.debugLogs, isTrue);
    expect(explorationDebug.emitEvents, isTrue);

    final explorationTapOnly = resolveViewportSemanticPolicy(
      profile: TugboatCaptureProfile.exploration,
      mode: TugboatViewportSemanticMode.tapResolutionOnly,
    );
    expect(explorationTapOnly.engineEnabled, isTrue);
    expect(explorationTapOnly.emitEvents, isFalse);

    final productionTapOnly = resolveViewportSemanticPolicy(
      profile: TugboatCaptureProfile.productionLean,
      mode: TugboatViewportSemanticMode.tapResolutionOnly,
    );
    expect(productionTapOnly.engineEnabled, isTrue);
    expect(productionTapOnly.emitEvents, isFalse);
    expect(productionTapOnly.holdPersistentSemanticsHandle, isFalse);

    final productionFull = resolveViewportSemanticPolicy(
      profile: TugboatCaptureProfile.productionLean,
      mode: TugboatViewportSemanticMode.full,
    );
    expect(productionFull.engineEnabled, isTrue);
    expect(productionFull.emitEvents, isTrue);
    expect(productionFull.holdPersistentSemanticsHandle, isFalse);

    final productionDefault = const TugboatReplayConfig(
      profile: TugboatCaptureProfile.productionLean,
    ).viewportSemanticPolicy;
    expect(productionDefault.engineEnabled, isTrue);
    expect(productionDefault.emitEvents, isFalse);
    expect(productionDefault.holdPersistentSemanticsHandle, isFalse);
  });

  test('replay config carries userId through copyWith', () {
    const config = TugboatReplayConfig(userId: 'user_1');

    expect(config.userId, 'user_1');
    expect(
      config.copyWith(profile: TugboatCaptureProfile.productionLean).userId,
      'user_1',
    );
    expect(config.copyWith(userId: 'user_2').userId, 'user_2');
  });
}
