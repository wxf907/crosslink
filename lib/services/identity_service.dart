import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../core/constants.dart';

/// 生成/读取本机稳定的 deviceId，以及默认设备名与类型。
class DeviceBootstrap {
  static const _kDeviceId = 'device_id';
  static const _fileUtils = MethodChannel('com.crosslink.crosslink/file_utils');

  /// 稳定 deviceId：由系统硬件标识派生，卸载重装保持不变。
  ///
  /// - Android：ANDROID_ID（同一设备 + 同一签名密钥下重装不变）
  /// - Windows：系统设备 GUID（同机重装应用不变）
  /// - 取不到硬件标识时：回退上次持久化的 ID，再无则生成随机 ID
  ///
  /// 历史：2.2.1 前为首装时生成的随机 UUID 存 SharedPreferences，
  /// 安卓卸载即清空，重装后对端会把它当成一台新设备。
  static Future<String> deviceId() async {
    final prefs = await SharedPreferences.getInstance();
    final seed = await _hardwareSeed();
    if (seed != null) {
      final id = deriveFromSeed(seed);
      if (id != prefs.getString(_kDeviceId)) {
        await prefs.setString(_kDeviceId, id);
      }
      return id;
    }
    var id = prefs.getString(_kDeviceId);
    if (id == null || id.isEmpty) {
      id = const Uuid().v4();
      await prefs.setString(_kDeviceId, id);
    }
    return id;
  }

  /// seed → 派生 ID（纯函数，供单测）。
  static String deriveFromSeed(String seed) {
    return sha256
        .convert(utf8.encode('crosslink-device:$seed'))
        .toString()
        .substring(0, 32);
  }

  static Future<String?> _hardwareSeed() async {
    try {
      if (Platform.isAndroid) {
        final id = await _fileUtils.invokeMethod<String>('androidId');
        // 部分早期 Android 8 机型 ANDROID_ID 恒为此错误固定值
        if (id != null && id.isNotEmpty && id != '9774d56d682e549c') {
          return 'android:$id';
        }
        return null;
      }
      if (Platform.isWindows) {
        final w = await DeviceInfoPlugin().windowsInfo;
        if (w.deviceId.isNotEmpty) return 'win:${w.deviceId}';
      }
    } catch (_) {
      // 通道缺失或系统 API 失败：交由调用方回退
    }
    return null;
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
