import 'dart:io';

import 'package:flutter_foreground_task/flutter_foreground_task.dart';

import '../core/logger.dart';

/// 前台服务任务处理器：仅用于让 App 进程常驻，从而保持局域网连接不被系统回收。
/// 真正的收发逻辑运行在主 isolate，这里无需业务代码。
class _KeepAliveHandler extends TaskHandler {
  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {}

  @override
  void onRepeatEvent(DateTime timestamp) {}

  @override
  Future<void> onDestroy(DateTime timestamp) async {}
}

@pragma('vm:entry-point')
void keepAliveCallback() {
  FlutterForegroundTask.setTaskHandler(_KeepAliveHandler());
}

/// 安卓后台保活封装（仅安卓生效；其他平台为空操作）。
class BackgroundKeepAlive {
  BackgroundKeepAlive._();
  static final BackgroundKeepAlive instance = BackgroundKeepAlive._();

  bool _inited = false;

  void _init() {
    if (_inited || !Platform.isAndroid) return;
    _inited = true;
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'crosslink_keepalive',
        channelName: 'CrossLink 在线保活',
        channelDescription: '保持局域网连接在线',
        channelImportance: NotificationChannelImportance.LOW,
        priority: NotificationPriority.LOW,
      ),
      iosNotificationOptions: const IOSNotificationOptions(),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.nothing(),
        autoRunOnBoot: false,
        allowWakeLock: true,
        allowWifiLock: true,
      ),
    );
  }

  /// 开启后台保活
  Future<void> start() async {
    if (!Platform.isAndroid) return;
    _init();
    try {
      await FlutterForegroundTask.requestNotificationPermission();
      if (await FlutterForegroundTask.isRunningService) return;
      await FlutterForegroundTask.startService(
        notificationTitle: 'CrossLink 保持在线',
        notificationText: '正在后台维持局域网连接',
        callback: keepAliveCallback,
      );
      log.i('BG', '后台保活已开启');
    } catch (e) {
      log.w('BG', '开启后台保活失败: $e');
    }
  }

  /// 关闭后台保活
  Future<void> stop() async {
    if (!Platform.isAndroid) return;
    try {
      if (await FlutterForegroundTask.isRunningService) {
        await FlutterForegroundTask.stopService();
        log.i('BG', '后台保活已关闭');
      }
    } catch (e) {
      log.w('BG', '关闭后台保活失败: $e');
    }
  }
}
