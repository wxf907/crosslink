import '../core/constants.dart';

/// 消息发送/接收状态
enum MessageStatus { sending, sent, failed, received }

/// 一条聊天消息（文本 / 图片 / 文件）
class ChatMessage {
  final String id;

  /// 会话对端设备 id（按设备分会话）
  final String peerId;

  /// 发送方设备 id
  final String fromId;

  /// 发送方设备名（冗余保存，便于历史展示）
  final String fromName;

  /// 是否本机发出
  final bool outgoing;

  final MessageKind kind;
  final DateTime time;

  /// 文本内容（kind==text/system）
  final String? text;

  /// 本地文件路径（图片/文件：接收完成或发送源文件的本地路径）
  final String? localPath;

  /// 文件名（图片/文件）
  final String? fileName;

  /// 文件大小字节（图片/文件）
  final int? fileSize;

  MessageStatus status;

  ChatMessage({
    required this.id,
    required this.peerId,
    required this.fromId,
    required this.fromName,
    required this.outgoing,
    required this.kind,
    required this.time,
    this.text,
    this.localPath,
    this.fileName,
    this.fileSize,
    this.status = MessageStatus.sent,
  });

  ChatMessage copyWith({MessageStatus? status, String? localPath}) =>
      ChatMessage(
        id: id,
        peerId: peerId,
        fromId: fromId,
        fromName: fromName,
        outgoing: outgoing,
        kind: kind,
        time: time,
        text: text,
        localPath: localPath ?? this.localPath,
        fileName: fileName,
        fileSize: fileSize,
        status: status ?? this.status,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'peerId': peerId,
        'fromId': fromId,
        'fromName': fromName,
        'outgoing': outgoing,
        'kind': kind.name,
        'time': time.millisecondsSinceEpoch,
        'text': text,
        'localPath': localPath,
        'fileName': fileName,
        'fileSize': fileSize,
        'status': status.name,
      };

  factory ChatMessage.fromJson(Map<String, dynamic> j) => ChatMessage(
        id: j['id'] as String,
        peerId: j['peerId'] as String,
        fromId: j['fromId'] as String,
        fromName: j['fromName'] as String,
        outgoing: j['outgoing'] as bool,
        kind: MessageKind.values.firstWhere((e) => e.name == j['kind'],
            orElse: () => MessageKind.text),
        time: DateTime.fromMillisecondsSinceEpoch(j['time'] as int),
        text: j['text'] as String?,
        localPath: j['localPath'] as String?,
        fileName: j['fileName'] as String?,
        fileSize: j['fileSize'] as int?,
        status: MessageStatus.values.firstWhere((e) => e.name == j['status'],
            orElse: () => MessageStatus.received),
      );
}
