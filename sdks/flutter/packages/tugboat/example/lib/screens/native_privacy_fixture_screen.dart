import 'package:flutter/material.dart';
import 'package:tugboat/tugboat.dart';

/// Device-lab fixture for native CPU privacy checks.
///
/// The secret tile is a 40×40 [TugboatSensitive] box in the top-left of a
/// 200×200 canvas. Edge, corner, and unmasked regions are labeled so a
/// decoded JPEG can be inspected after rotation, scale, and inset changes.
class NativePrivacyFixtureScreen extends StatelessWidget {
  const NativePrivacyFixtureScreen({super.key});

  static const canvasSize = 200.0;
  static const secretSize = 40.0;
  static const secretFill = Color(0xff00ff00);
  static const publicFill = Color(0xffff0000);
  static const edgeFill = Color(0xff0000ff);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Native privacy fixture')),
      body: Center(
        child: SizedBox(
          width: canvasSize,
          height: canvasSize,
          child: Stack(
            children: [
              const Positioned.fill(child: ColoredBox(color: publicFill)),
              const Positioned(
                left: 0,
                top: 0,
                width: secretSize,
                height: secretSize,
                child: TugboatSensitive(
                  child: ColoredBox(
                    color: secretFill,
                    child: SizedBox.expand(),
                  ),
                ),
              ),
              const Positioned(
                right: 0,
                bottom: 0,
                width: secretSize,
                height: secretSize,
                child: TugboatSensitive(
                  child: ColoredBox(color: edgeFill, child: SizedBox.expand()),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
