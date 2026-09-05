import 'dart:typed_data';
import '../models/identity.dart';

/// 传输层事件回调集合。
///
/// UI/状态层实现这些回调以接收网络事件；具体传输实现（局域网 / 未来公网）
/// 只需实现 [MessageTransport] 接口即可无缝替换，满足「预留互联网传输接口」。
class TransportCallbacks {
  /// 在线设备列表发生变化
  final void Function(List<RemoteDevice> devices) onDevicesChanged;

  /// 收到文本消息
  final void Function(RemoteDevice from, String msgId, String text, DateTime ts)
      onText;

  /// 收到图片（已落地到 savePath）
  final void Function(
          RemoteDevice from, String msgId, String savePath, String name)
      onImage;

  /// 收到文件邀约
  final void Function(RemoteDevice from, String taskId, String name, int size)
      onFileOffer;

  /// 文件接收进度
  final void Function(String taskId, int received, int total) onFileProgress;

  /// 文件接收完成
  final void Function(String taskId, String savePath) onFileDone;

  /// 文件传输失败
  final void Function(String taskId, String reason) onFileError;

  /// 扫码登录：收到授权凭证（本设备被手机授权登录）
  final void Function(Identity granted) onLoginGranted;

  /// 收到对端同步来的头像（同账号设备间同步，较新时间戳胜出）
  final void Function(Uint8List bytes, int timestamp)? onAvatarSync;

  const TransportCallbacks({
    required this.onDevicesChanged,
    required this.onText,
    required this.onImage,
    required this.onFileOffer,
    required this.onFileProgress,
    required this.onFileDone,
    required this.onFileError,
    required this.onLoginGranted,
    this.onAvatarSync,
  });
}

/// 抽象传输接口。V1.0 由局域网实现；V2.0 可新增公网实现而不改动上层。
abstract class MessageTransport {
  /// 启动：绑定发现与监听、开始广播上线
  Future<void> start(Identity identity, TransportCallbacks callbacks);

  /// 停止：广播下线并释放端口
  Future<void> stop();

  /// 手动触发一次刷新（重新广播 / 主动探测）
  void refresh();

  /// 发送文本
  Future<void> sendText(RemoteDevice to, String msgId, String text);

  /// 发送图片字节
  Future<void> sendImage(
      RemoteDevice to, String msgId, Uint8List bytes, String name);

  /// 发送文件，progress 回调 (已发送, 总大小)
  Future<void> sendFile(
    RemoteDevice to,
    String taskId,
    String filePath,
    String fileName,
    int size, {
    required void Function(int sent, int total) onProgress,
  });

  /// 扫码登录：待登录设备开启一次性授权监听，返回二维码需要的连接信息。
  /// 返回 {host, port, nonce}。onGranted 在收到授权凭证时回调（登录前 callbacks 尚未就绪）。
  Future<Map<String, dynamic>> startLoginBeacon(
      void Function(Identity granted) onGranted);

  /// 扫码登录：已登录设备把本机凭证下发给目标设备
  Future<void> grantLogin(String host, int port, Identity identity);
}
