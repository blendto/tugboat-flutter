import 'dart:io';

import 'package:integration_test/integration_test_driver.dart';

/// Writes `build/<TBPROF_OUT>.json` (default `capture_profile`) on the host.
Future<void> main() => integrationDriver(
  responseDataCallback: (data) => writeResponseData(
    data,
    testOutputFilename: Platform.environment['TBPROF_OUT'] ?? 'capture_profile',
  ),
);
