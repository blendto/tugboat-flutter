import 'package:flutter/material.dart';
import 'package:tugboat/tugboat.dart';

import 'tugboat_widgets.g.dart';
import 'screens/home_screen.dart';

/// HTTP collector config for production ingestion. See
/// `docs/integration/collector.md` for setup. Keep API keys out of source
/// control — mobile tokens are client-visible.
const TugboatCollectorConfig? _productionCollector = null;

void main() => runApp(const ReplayDemoApp());

class ReplayDemoApp extends StatelessWidget {
  const ReplayDemoApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Tugboat Replay Demo',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
        useMaterial3: true,
      ),
      navigatorObservers: [TugboatReplay.navigatorObserver],
      builder: (context, child) => TugboatReplay.wrapApp(
        config: TugboatReplayConfig(
          // Local CLI exploration collector over adb reverse.
          explorationCollectorUrl: 'ws://127.0.0.1:7832/sdk',
          appInfo: const TugboatCollectorAppInfo(
            name: 'Tugboat Replay Demo',
            version: '1.0.0',
            buildNumber: '1',
            installationId: 'demo-installation',
          ),
          // Standalone HTTP collector for production ingestion.
          collector: _productionCollector,
          widgetNames: tugboatWidgetNames,
        ),
        child: child!,
      ),
      home: const HomeScreen(),
    );
  }
}
