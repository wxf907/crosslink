/// 文件传输任务状态
enum TransferState { pending, transferring, completed, failed, canceled }

/// 文件传输任务（用于进度条 / 速度 / 剩余时间展示与重发）
class TransferTask {
  final String taskId;
  final String peerId;
  final String fileName;
  final int totalBytes;
  final bool outgoing;

  /// 发送端：源文件路径；接收端：目标保存路径
  final String path;

  int transferredBytes;
  TransferState state;
  DateTime startedAt;
  DateTime updatedAt;

  /// 关联的消息 id（便于失败重发时定位）
  final String messageId;

  TransferTask({
    required this.taskId,
    required this.peerId,
    required this.fileName,
    required this.totalBytes,
    required this.outgoing,
    required this.path,
    required this.messageId,
    this.transferredBytes = 0,
    this.state = TransferState.pending,
  })  : startedAt = DateTime.now(),
        updatedAt = DateTime.now();

  double get progress =>
      totalBytes <= 0 ? 0 : (transferredBytes / totalBytes).clamp(0.0, 1.0);

  /// 平均速度（字节/秒）
  double get bytesPerSecond {
    final secs = updatedAt.difference(startedAt).inMilliseconds / 1000.0;
    if (secs <= 0) return 0;
    return transferredBytes / secs;
  }

  /// 剩余时间（秒），无法估算时返回 null
  int? get etaSeconds {
    final bps = bytesPerSecond;
    if (bps <= 0) return null;
    final remain = totalBytes - transferredBytes;
    return (remain / bps).round();
  }
}
