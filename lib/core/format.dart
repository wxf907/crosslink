import 'package:intl/intl.dart';

/// 通用格式化工具
class Fmt {
  Fmt._();

  /// 人类可读文件大小
  static String size(int bytes) {
    if (bytes < 1024) return '$bytes B';
    const units = ['KB', 'MB', 'GB', 'TB'];
    double v = bytes / 1024;
    int i = 0;
    while (v >= 1024 && i < units.length - 1) {
      v /= 1024;
      i++;
    }
    return '${v.toStringAsFixed(v >= 100 ? 0 : 1)} ${units[i]}';
  }

  /// 传输速度
  static String speed(double bytesPerSec) => '${size(bytesPerSec.round())}/s';

  /// 剩余时间
  static String eta(int? seconds) {
    if (seconds == null) return '--';
    if (seconds < 60) return '${seconds}s';
    final m = seconds ~/ 60;
    final s = seconds % 60;
    return '${m}m${s}s';
  }

  /// 消息时间：今天显示 HH:mm，否则 MM-dd HH:mm
  static String msgTime(DateTime t) {
    final now = DateTime.now();
    final sameDay = now.year == t.year && now.month == t.month && now.day == t.day;
    return DateFormat(sameDay ? 'HH:mm' : 'MM-dd HH:mm').format(t);
  }
}
