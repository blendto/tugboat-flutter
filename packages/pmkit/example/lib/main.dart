import 'package:flutter/material.dart';
import 'package:pmkit/pmkit.dart';

import 'pmkit_widgets.g.dart';
import 'screens/home_screen.dart';

/// Example collector configuration for the standalone HTTP collector.
///
/// Keep API keys out of source control in production apps. Tokens are
/// client-visible on mobile, so use environment-specific keys with the
/// narrowest scope possible.
const PmkitCollectorConfig? _productionCollector = null;
// const _productionCollector = PmkitCollectorConfig(
//   baseUrl: 'http://localhost:3000',
//   apiKey: 'pmk_blend-app-dev-secret',
//   appInfo: PmkitCollectorAppInfo(
//     name: 'PMKit Replay Demo',
//     version: '1.0.0',
//     buildNumber: '1',
//     installationId: 'demo-installation',
//   ),
//   deviceInfo: PmkitCollectorDeviceInfo(
//     id: 'demo-device',
//     platform: 'ios',
//     screenSize: PmkitCollectorScreenSize(width: 390, height: 844),
//     screenDensity: 3,
//     screenDpi: 460,
//     screenPixelDensity: 3,
//   ),
//   ipInfo: PmkitCollectorIpInfo(ip: '127.0.0.1'),
//   locale: PmkitCollectorLocaleInfo(
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
      title: 'PMKit Replay Demo',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
        useMaterial3: true,
      ),
      navigatorObservers: [PmkitReplay.navigatorObserver],
      builder: (context, child) => PmkitReplay.wrapApp(
        config: PmkitReplayConfig(
          // Local CLI exploration collector over adb reverse.
          explorationCollectorUrl: 'ws://127.0.0.1:7832/sdk',
          appInfo: const PmkitCollectorAppInfo(
            name: 'PMKit Replay Demo',
            version: '1.0.0',
            buildNumber: '1',
            installationId: 'demo-installation',
          ),
          // Standalone HTTP collector for production ingestion.
          collector: _productionCollector,
          widgetNames: pmkitWidgetNames,
        ),
        child: child!,
      ),
      home: const HomeScreen(),
    );
  }
}
