import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:hotkey_manager/hotkey_manager.dart';

import '../core/logger.dart';

/// 桌面端全局快捷键服务：注册可自定义的截图快捷键（默认 Alt+A）。
class HotkeyService {
  HotkeyService._();
  static final HotkeyService instance = HotkeyService._();

  bool _inited = false;

  /// 默认截图快捷键：Alt + A（系统级全局）
  static HotKey defaultScreenshotHotKey() => HotKey(
        key: PhysicalKeyboardKey.keyA,
        modifiers: [HotKeyModifier.alt],
        scope: HotKeyScope.system,
      );

  Future<void> ensureInit() async {
    if (_inited) return;
    _inited = true;
    // 启动时清理历史注册，避免热重启后重复
    await hotKeyManager.unregisterAll();
  }

  /// 从持久化 JSON 解析快捷键，失败或为空回退默认值
  HotKey resolve(String? json) {
    if (json == null || json.isEmpty) return defaultScreenshotHotKey();
    try {
      return HotKey.fromJson(jsonDecode(json) as Map<String, dynamic>);
    } catch (_) {
      return defaultScreenshotHotKey();
    }
  }

  String encode(HotKey hotKey) => jsonEncode(hotKey.toJson());

  /// 注册截图快捷键，触发时回调 onTrigger
  Future<void> registerScreenshot(
      String? json, VoidCallback onTrigger) async {
    await ensureInit();
    await hotKeyManager.unregisterAll();
    final hk = resolve(json);
    try {
      await hotKeyManager.register(hk, keyDownHandler: (_) => onTrigger());
      log.i('Hotkey', '截图快捷键已注册: ${hk.debugName}');
    } catch (e) {
      log.w('Hotkey', '快捷键注册失败: $e');
    }
  }

  Future<void> unregisterAll() async {
    if (!_inited) return;
    await hotKeyManager.unregisterAll();
  }
}
