import 'dart:io';

import 'package:battery_plus/battery_plus.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:disk_space_plus/disk_space_plus.dart';

import 'collector_config.dart';

/// Session-start runtime facts observed from the host device.
///
/// Each field is omitted independently when the platform cannot observe it.
class TugboatDeviceRuntimeSnapshot {
  const TugboatDeviceRuntimeSnapshot({
    this.batteryPercent,
    this.storageFreeMb,
    this.ramMb,
    this.networkType,
  });

  final int? batteryPercent;
  final int? storageFreeMb;
  final int? ramMb;
  final String? networkType;

  static Future<TugboatDeviceRuntimeSnapshot> capture() async {
    return TugboatDeviceRuntimeSnapshot(
      batteryPercent: await _loadBatteryPercent(),
      storageFreeMb: await _loadStorageFreeMb(),
      ramMb: await _loadRamMb(),
      networkType: await _loadNetworkType(),
    );
  }
}

Future<int?> _loadBatteryPercent() async {
  try {
    final level = await Battery().batteryLevel;
    if (level < 0 || level > 100) return null;
    return level;
  } on Object {
    return null;
  }
}

Future<int?> _loadStorageFreeMb() async {
  try {
    final freeMb = await DiskSpacePlus().getFreeDiskSpace;
    if (freeMb == null || freeMb <= 0) return null;
    return freeMb.round();
  } on Object {
    return null;
  }
}

Future<int?> _loadRamMb() async {
  if (!Platform.isAndroid) return null;
  try {
    final android = await DeviceInfoPlugin().androidInfo;
    if (android.physicalRamSize <= 0) return null;
    return android.physicalRamSize ~/ (1024 * 1024);
  } on Object {
    return null;
  }
}

Future<String?> _loadNetworkType() async {
  try {
    final results = await Connectivity().checkConnectivity();
    return _mapConnectivity(results);
  } on Object {
    return null;
  }
}

String _mapConnectivity(List<ConnectivityResult> results) {
  if (results.isEmpty ||
      results.every((result) => result == ConnectivityResult.none)) {
    return TugboatCollectorNetworkType.none;
  }
  if (results.contains(ConnectivityResult.wifi)) {
    return TugboatCollectorNetworkType.wifi;
  }
  if (results.contains(ConnectivityResult.ethernet)) {
    return TugboatCollectorNetworkType.ethernet;
  }
  if (results.contains(ConnectivityResult.vpn)) {
    return TugboatCollectorNetworkType.vpn;
  }
  if (results.contains(ConnectivityResult.mobile)) {
    return TugboatCollectorNetworkType.cellular;
  }
  if (results.contains(ConnectivityResult.bluetooth) ||
      results.contains(ConnectivityResult.other)) {
    return TugboatCollectorNetworkType.other;
  }
  return TugboatCollectorNetworkType.other;
}
