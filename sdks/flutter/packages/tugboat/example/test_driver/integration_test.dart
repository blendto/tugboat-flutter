import 'dart:io';

import 'package:integration_test/integration_test_driver.dart';

/// Writes `build/<TBPROF_OUT>.json` (default `capture_profile`) on the host.
///
/// The data is written even when a test fails, so a partial checklist or
/// benchmark still reaches the device report.
Future<void> main() => integrationDriver(
  writeResponseOnFailure: true,
  responseDataCallback: (data) => writeResponseData(
    data,
    testOutputFilename: Platform.environment['TBPROF_OUT'] ?? 'capture_profile',
  ),
);
