import 'package:flutter/foundation.dart';

/// 全局常量配置
class AppConst {
  AppConst._();

  /// 应用名
  static const String appName = 'CrossLink';

  /// UDP 设备发现端口（同一账号组内广播）
  static const int discoveryPort = 47821;

  /// TCP 消息/文件服务监听端口（固定值）：
  /// - 防火墙按端口放行（不再绑定 exe 路径，重装/换路径不误报）
  /// - 手动按 IP 直连可直接连 host:此端口，无需先广播获知
  /// 若被占用，运行时自动回退为随机端口（广播里携带真实端口）
  static const int tcpPort = 47822;

  /// IPP 打印服务首选端口：标准 631，Windows 添加向导默认值，零填写体验；
  /// 被占用时回退 47823。防火墙 TCP 规则覆盖 47822,47823,631。
  static const int printPort = 631;
  static const int printPortAlt = 47823;

  /// UDP 设备心跳广播间隔
  static const Duration announceInterval = Duration(seconds: 3);

  /// UDP 广播判定离线阈值（超过该时长未收到广播视为离线）
  static const Duration deviceTimeout = Duration(seconds: 10);

  /// 文件传输分块大小（256KB：减少帧数量与 flush 次数，降低界面卡顿）
  static const int fileChunkSize = 256 * 1024;

  /// 协议版本（2 = 持久长连接 + TCP 心跳 + 应用层确认）
  static const int protocolVersion = 2;

  /// V2 持久连接 TCP 心跳间隔
  static const Duration pingInterval = Duration(seconds: 3);

  /// V2 连接判死阈值（超过该时长无任何往来帧则判定连接失效）
  static const Duration connDeadAfter = Duration(seconds: 9);

  /// V2 连接断开后仍显示在线的宽限期（重连窗口，过后如实显示离线）
  static const Duration deadGrace = Duration(seconds: 5);

  /// 对端被认为仍存活（允许重连）的 UDP 最后可见窗口
  static const Duration peerFreshWindow = Duration(seconds: 45);

  /// 是否桌面端
  static bool get isDesktop =>
      defaultTargetPlatform == TargetPlatform.windows ||
      defaultTargetPlatform == TargetPlatform.linux ||
      defaultTargetPlatform == TargetPlatform.macOS;

  /// 是否移动端
  static bool get isMobile =>
      defaultTargetPlatform == TargetPlatform.android ||
      defaultTargetPlatform == TargetPlatform.iOS;
}

/// 设备类型
enum DeviceType {
  windows,
  android,
  other;

  String get label {
    switch (this) {
      case DeviceType.windows:
        return 'Windows 电脑';
      case DeviceType.android:
        return '安卓手机';
      case DeviceType.other:
        return '其他设备';
    }
  }

  static DeviceType fromString(String? v) {
    switch (v) {
      case 'windows':
        return DeviceType.windows;
      case 'android':
        return DeviceType.android;
      default:
        return DeviceType.other;
    }
  }
}

/// 消息类型
enum MessageKind { text, image, file, system }
