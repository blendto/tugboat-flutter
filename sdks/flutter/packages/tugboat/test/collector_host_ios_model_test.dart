import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tugboat/src/collector_host.dart';

IosDeviceInfo _ios({required String machine, String model = 'iPhone'}) =>
    IosDeviceInfo.fromMap({
      'name': 'Test iPhone',
      'systemName': 'iOS',
      'systemVersion': '18.1',
      'model': model,
      'modelName': 'iPhone 16 Pro',
      'localizedModel': model,
      'identifierForVendor': null,
      'freeDiskSize': 0,
      'totalDiskSize': 0,
      'isPhysicalDevice': true,
      'isiOSAppOnMac': false,
      'physicalRamSize': 0,
      'availableRamSize': 0,
      'utsname': {
        'sysname': 'Darwin',
        'nodename': 'localhost',
        'release': '24.1.0',
        'version': 'Darwin Kernel',
        'machine': machine,
      },
    });

void main() {
  group('TugboatCollectorHost.iosModelIdentifier', () {
    test('reports the hardware identifier, not the family name', () {
      expect(
        TugboatCollectorHost.iosModelIdentifier(_ios(machine: 'iPhone17,1')),
        'iPhone17,1',
      );
    });

    test('reports the simulated device identifier on the simulator', () {
      // device_info_plus puts SIMULATOR_MODEL_IDENTIFIER in utsname.machine
      // on the simulator instead of the host CPU architecture.
      expect(
        TugboatCollectorHost.iosModelIdentifier(_ios(machine: 'iPhone16,2')),
        'iPhone16,2',
      );
    });

    test('falls back to the family name when the identifier is empty', () {
      expect(
        TugboatCollectorHost.iosModelIdentifier(_ios(machine: '  ')),
        'iPhone',
      );
    });
  });
}
