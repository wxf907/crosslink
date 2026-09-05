import 'dart:convert';
import 'package:crypto/crypto.dart';
import '../core/constants.dart';

/// 本机身份 / 账号凭证。
///
/// 采用「无服务器凭证组网」：账号+密码派生出 groupId（组密钥）。
/// 同一账号密码的设备拥有相同 groupId，在局域网内自动互相识别与互认，
/// 无需任何中心服务器。password 本身不落盘，仅保存派生出的 groupId。
class Identity {
  /// 账号（展示用，也参与派生）
  final String accountId;

  /// 组密钥：SHA-256(accountId + ':' + password) 的十六进制
  final String groupId;

  /// 本设备唯一 id（首次启动生成，持久化）
  final String deviceId;

  /// 设备名称（可自定义）
  final String deviceName;

  /// 设备类型
  final DeviceType deviceType;

  /// 头像本地文件路径（可空，空则显示默认图标）
  final String? avatarPath;

  const Identity({
    required this.accountId,
    required this.groupId,
    required this.deviceId,
    required this.deviceName,
    required this.deviceType,
    this.avatarPath,
  });

  /// 由账号密码派生 groupId
  static String deriveGroupId(String accountId, String password) {
    final bytes = utf8.encode('${accountId.trim()}:$password');
    return sha256.convert(bytes).toString();
  }

  Identity copyWith({String? deviceName, String? avatarPath}) => Identity(
        accountId: accountId,
        groupId: groupId,
        deviceId: deviceId,
        deviceName: deviceName ?? this.deviceName,
        deviceType: deviceType,
        avatarPath: avatarPath ?? this.avatarPath,
      );

  Map<String, dynamic> toJson() => {
        'accountId': accountId,
        'groupId': groupId,
        'deviceId': deviceId,
        'deviceName': deviceName,
        'deviceType': deviceType.name,
        'avatarPath': avatarPath,
      };

  factory Identity.fromJson(Map<String, dynamic> j) => Identity(
        accountId: j['accountId'] as String,
        groupId: j['groupId'] as String,
        deviceId: j['deviceId'] as String,
        deviceName: j['deviceName'] as String,
        deviceType: DeviceType.fromString(j['deviceType'] as String?),
        avatarPath: j['avatarPath'] as String?,
      );
}

/// 局域网中被发现的远端设备
class RemoteDevice {
  final String deviceId;
  String name;
  final DeviceType type;
  String host; // ip
  int tcpPort; // 对端 TCP 服务端口
  DateTime lastSeen;

  /// 对端协议版本（UDP 广播携带；1=旧版按需连接，2=持久连接+心跳）
  int version;

  /// 在线状态：由传输层综合「持久连接存活 + TCP 心跳 + UDP 新鲜度」计算，
  /// 不再单纯依赖 UDP 广播时间（旧版“显示在线实际不在线”的根源）
  bool online;

  /// 能收到对方广播、但 TCP 连不上（多为对方防火墙入站未放行）。
  /// 与"真离线"区分开，避免用户误以为对方没开机。
  bool unreachable;

  RemoteDevice({
    required this.deviceId,
    required this.name,
    required this.type,
    required this.host,
    required this.tcpPort,
    required this.lastSeen,
    this.version = 1,
    this.online = false,
    this.unreachable = false,
  });
}
