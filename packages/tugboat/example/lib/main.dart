import 'package:flutter/material.dart';
import 'package:tugboat/tugboat.dart';

import 'tugboat_widgets.g.dart';
import 'screens/home_screen.dart';

/// Example collector configuration for the standalone HTTP collector.
///
/// Keep API keys out of source control in production apps. Tokens are
/// client-visible on mobile, so use environment-specific keys with the
/// narrowest scope possible.
const TugboatCollectorConfig? _productionCollector = null;
// const _productionCollector = TugboatCollectorConfig(
//   baseUrl: TugboatCollectorDefaults.productionBaseUrl,
//   apiKey: 'pmk_example_dev_token',
//   appInfo: TugboatCollectorAppInfo(
//     name: 'Tugboat Replay Demo',
//     version: '1.0.0',
//     buildNumber: '1',
//     installationId: 'demo-installation',
//   ),
//   deviceInfo: TugboatCollectorDeviceInfo(
//     id: 'demo-device',
//     platform: 'ios',
//     screenSize: TugboatCollectorScreenSize(width: 390, height: 844),
//     screenDensity: 3,
//     screenDpi: 460,
//     screenPixelDensity: 3,
//   ),
//   ipInfo: TugboatCollectorIpInfo(ip: '127.0.0.1'),
//   locale: TugboatCollectorLocaleInfo(
//     language: 'en',
//     country: 'US',
//     timezone: 'America/New_York',
//   ),
// );

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
