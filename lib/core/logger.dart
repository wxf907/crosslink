import 'dart:collection';
import 'package:flutter/foundation.dart';
import 'package:intl/intl.dart';

/// 单条日志
class LogEntry {
  final DateTime time;
  final String level; // I / W / E
  final String tag;
  final String message;

  LogEntry(this.level, this.tag, this.message) : time = DateTime.now();

  @override
  String toString() {
    final t = DateFormat('HH:mm:ss.SSS').format(time);
    return '[$t][$level][$tag] $message';
  }
}

/// 内存日志服务：供“设置 → 日志”页面查看，同时输出到 debugPrint
class LogService extends ChangeNotifier {
  LogService._();
  static final LogService instance = LogService._();

  final ListQueue<LogEntry> _entries = ListQueue<LogEntry>();
  static const int _maxEntries = 500;

  List<LogEntry> get entries => _entries.toList(growable: false);

  void _add(String level, String tag, String message) {
    final e = LogEntry(level, tag, message);
    _entries.addLast(e);
    while (_entries.length > _maxEntries) {
      _entries.removeFirst();
    }
    debugPrint(e.toString());
    notifyListeners();
  }

  void i(String tag, String message) => _add('I', tag, message);
  void w(String tag, String message) => _add('W', tag, message);
  void e(String tag, String message) => _add('E', tag, message);

  void clear() {
    _entries.clear();
    notifyListeners();
  }

  String exportText() => entries.map((e) => e.toString()).join('\n');
}

/// 全局便捷访问
LogService get log => LogService.instance;
