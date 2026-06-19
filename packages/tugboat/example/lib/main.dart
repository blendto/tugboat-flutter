import 'package:flutter/material.dart';
import 'package:tugboat/tugboat.dart';

import 'tugboat_widgets.g.dart';
import 'screens/home_screen.dart';

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
        config: const TugboatReplayConfig(
          explorationCollectorUrl: 'ws://127.0.0.1:7832/sdk',
          widgetNames: tugboatWidgetNames,
        ),
        child: child!,
      ),
      home: const HomeScreen(),
    );
  }
}
