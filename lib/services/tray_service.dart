import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

/// 系统托盘常驻（仅桌面端）。
/// 左键单击唤回主窗口；右键菜单：打开主界面 / 退出。
class TrayService with TrayListener {
  static final TrayService instance = TrayService._();
  TrayService._();

  static bool get supported =>
      Platform.isWindows || Platform.isLinux || Platform.isMacOS;

  VoidCallback? onExitRequested;

  bool _ready = false;

  Future<void> init() async {
    if (!supported || _ready) return;
    try {
      // 必须用 .ico：Windows 原生 LoadImage(IMAGE_ICON) 不认 PNG，
      // 且失败不报错，只会得到一个空白"阴影"图标
      await trayManager.setIcon('assets/images/tray_icon.ico');
      await trayManager.setToolTip('CrossLink 跨端互传');
      await trayManager.setContextMenu(Menu(items: [
        MenuItem(key: 'open', label: '打开主界面'),
        MenuItem.separator(),
        MenuItem(key: 'exit', label: '退出 CrossLink'),
      ]));
      trayManager.addListener(this);
      _ready = true;
    } catch (_) {
      // 托盘创建失败不影响主功能（如缺少图标资源的开发环境）
    }
  }

  Future<void> disposeTray() async {
    if (!_ready) return;
    trayManager.removeListener(this);
    await trayManager.destroy();
    _ready = false;
  }

  @override
  void onTrayIconMouseDown() => showWindow();

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    if (menuItem.key == 'open') {
      showWindow();
    } else if (menuItem.key == 'exit') {
      onExitRequested?.call();
    }
  }

  Future<void> showWindow() async {
    if (!await windowManager.isVisible()) await windowManager.show();
    if (await windowManager.isMinimized()) await windowManager.restore();
    await windowManager.focus();
  }
}
