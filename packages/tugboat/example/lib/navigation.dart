import 'package:flutter/material.dart';

void pushDemoScreen(
  BuildContext context, {
  required String routeName,
  required Widget screen,
}) {
  Navigator.push<void>(
    context,
    MaterialPageRoute<void>(
      settings: RouteSettings(name: routeName),
      builder: (_) => screen,
    ),
  );
}
