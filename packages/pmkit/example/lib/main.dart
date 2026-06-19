import 'package:flutter/material.dart';
import 'package:pmkit/pmkit.dart';

import 'pmkit_widgets.g.dart';
import 'screens/home_screen.dart';

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
        config: const PmkitReplayConfig(
          explorationCollectorUrl: 'ws://127.0.0.1:7832/sdk',
          widgetNames: pmkitWidgetNames,
        ),
        child: child!,
      ),
      home: const HomeScreen(),
    );
  }
}
