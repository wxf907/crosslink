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

/// 设备角色：这台机器「是干什么用的」。
///
/// 与 [DeviceType] 的分工——type 表示什么系统（Windows/安卓），
/// role 表示用途（办公机/常开主机/手机…）。一个人往往有多台同系统设备，
/// 只按 type 显示图标时它们长得一模一样，只能靠读名字区分；
/// 因此由本机在「设置」里选定角色，随 UDP announce 与 TCP hello 广播给
/// 同组设备，列表据此显示不同角标图标。
///
/// 兼容性：旧版本对端不带该字段，[fromString] 回退 [DeviceRole.unset]，
/// 界面自动退回按 [DeviceType] 选图标，不影响任何既有功能。
enum DeviceRole {
  unset,
  office,
  host,
  laptop,
  phone,
  tablet,
  shared;

  String get label {
    switch (this) {
      case DeviceRole.unset:
        return '未设置';
      case DeviceRole.office:
        return '办公机';
      case DeviceRole.host:
        return '常开主机';
      case DeviceRole.laptop:
        return '笔记本';
      case DeviceRole.phone:
        return '手机';
      case DeviceRole.tablet:
        return '平板';
      case DeviceRole.shared:
        return '公用机';
    }
  }

  static DeviceRole fromString(String? v) => DeviceRole.values.firstWhere(
        (r) => r.name == v,
        orElse: () => DeviceRole.unset,
      );
}

/// 消息类型
enum MessageKind { text, image, file, system }
