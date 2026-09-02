import 'package:flutter_test/flutter_test.dart';
import 'package:tugboat/tugboat.dart';

void main() {
  test('resolveViewportSemanticPolicy uses explicit event capability', () {
    expect(
      resolveViewportSemanticPolicy(mode: TugboatViewportSemanticMode.off),
      TugboatViewportSemanticPolicy.off,
    );

    final full = resolveViewportSemanticPolicy(
      mode: TugboatViewportSemanticMode.full,
      emitEvents: true,
    );
    expect(full.engineEnabled, isTrue);
    expect(full.emitEvents, isTrue);
    expect(full.debugLogs, isFalse);
    expect(full.holdPersistentSemanticsHandle, isTrue);

    final debug = resolveViewportSemanticPolicy(
      mode: TugboatViewportSemanticMode.fullWithDebugLogs,
      emitEvents: true,
    );
    expect(debug.debugLogs, isTrue);
    expect(debug.emitEvents, isTrue);

    final tapOnly = resolveViewportSemanticPolicy(
      mode: TugboatViewportSemanticMode.tapResolutionOnly,
      emitEvents: true,
    );
    expect(tapOnly.engineEnabled, isTrue);
    expect(tapOnly.emitEvents, isFalse);

    final defaultPolicy = const TugboatReplayConfig(
      enabled: true,
    ).viewportSemanticPolicy;
    expect(defaultPolicy.engineEnabled, isTrue);
    expect(defaultPolicy.emitEvents, isFalse);
    expect(defaultPolicy.holdPersistentSemanticsHandle, isFalse);
  });

  test('replay config carries userId through copyWith', () {
    const config = TugboatReplayConfig(userId: 'user_1');

    expect(config.userId, 'user_1');
    expect(config.copyWith(enabled: true).userId, 'user_1');
    expect(config.copyWith(userId: 'user_2').userId, 'user_2');
  });
}
