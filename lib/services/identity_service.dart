import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../core/constants.dart';

/// 生成/读取本机稳定的 deviceId，以及默认设备名与类型。
class DeviceBootstrap {
  static const _kDeviceId = 'device_id';

  /// 稳定 deviceId：首次生成并持久化，之后复用
  static Future<String> deviceId() async {
    final prefs = await SharedPreferences.getInstance();
    var id = prefs.getString(_kDeviceId);
    if (id == null || id.isEmpty) {
      id = const Uuid().v4();
      await prefs.setString(_kDeviceId, id);
    }
    return id;
  }

  static DeviceType currentType() {
    if (Platform.isWindows) return DeviceType.windows;
    if (Platform.isAndroid) return DeviceType.android;
    return DeviceType.other;
  }

  /// 默认设备名：优先取系统主机名/机型
  static Future<String> defaultName() async {
    final info = DeviceInfoPlugin();
    try {
      if (Platform.isWindows) {
        final w = await info.windowsInfo;
        return w.computerName;
      }
      if (Platform.isAndroid) {
        final a = await info.androidInfo;
        return '${a.brand} ${a.model}';
      }
    } catch (_) {}
    return Platform.localHostname;
  }
}
