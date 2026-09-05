import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/logger.dart';
import '../models/app_settings.dart';
import '../models/identity.dart';
import '../models/message.dart';

/// 本地持久化：身份、设置、聊天记录、默认目录。
class StorageService {
  static const _kIdentity = 'identity';
  static const _kSettings = 'settings';

  late final SharedPreferences _prefs;
  late final Directory _appDir; // 应用数据根目录
  late final Directory _historyDir; // 聊天记录目录

  Future<void> init() async {
    _prefs = await SharedPreferences.getInstance();
    _appDir = await getApplicationSupportDirectory();
    _historyDir = Directory(p.join(_appDir.path, 'history'));
    if (!await _historyDir.exists()) {
      await _historyDir.create(recursive: true);
    }
    log.i('Storage', '数据目录 ${_appDir.path}');
  }

  // ---------------- 身份 ----------------

  Identity? loadIdentity() {
    final s = _prefs.getString(_kIdentity);
    if (s == null) return null;
    try {
      return Identity.fromJson(jsonDecode(s) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  Future<void> saveIdentity(Identity id) =>
      _prefs.setString(_kIdentity, jsonEncode(id.toJson()));

  Future<void> clearIdentity() => _prefs.remove(_kIdentity);

  /// 将选中的头像文件复制到应用目录，返回持久路径
  Future<String> saveAvatar(String srcPath) async {
    final ext = p.extension(srcPath).isEmpty ? '.png' : p.extension(srcPath);
    // 文件名带时间戳，避免图片缓存导致不刷新
    final dst = p.join(
        _appDir.path, 'avatar_${DateTime.now().millisecondsSinceEpoch}$ext');
    await File(srcPath).copy(dst);
    return dst;
  }

  /// 将对端同步来的头像字节保存到应用目录（文件名保留对方时间戳，
  /// 供两端比较新旧；较新头像胜出）
  Future<String> saveAvatarBytes(Uint8List bytes, int timestampMs) async {
    final dst = p.join(_appDir.path, 'avatar_$timestampMs.png');
    await File(dst).writeAsBytes(bytes, flush: true);
    return dst;
  }

  // ---------------- 设置 ----------------

  AppSettings loadSettings() {
    final s = _prefs.getString(_kSettings);
    if (s == null) return AppSettings();
    try {
      return AppSettings.fromJson(jsonDecode(s) as Map<String, dynamic>);
    } catch (_) {
      return AppSettings();
    }
  }

  Future<void> saveSettings(AppSettings s) =>
      _prefs.setString(_kSettings, jsonEncode(s.toJson()));

  // ---------------- 默认接收目录 ----------------

  /// 默认专属接收目录：文档/CrossLink/Received（桌面）或应用目录/Received（移动）
  Future<String> defaultSaveDir() async {
    Directory base;
    try {
      base = await getDownloadsDirectory() ??
          await getApplicationDocumentsDirectory();
    } catch (_) {
      base = await getApplicationDocumentsDirectory();
    }
    final dir = Directory(p.join(base.path, 'CrossLink', 'Received'));
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir.path;
  }

  // ---------------- 聊天记录（按对端设备分文件）----------------

  File _historyFile(String peerId) =>
      File(p.join(_historyDir.path, '$peerId.jsonl'));

  List<ChatMessage> loadHistory(String peerId) {
    final f = _historyFile(peerId);
    if (!f.existsSync()) return [];
    // 同 id 多行时取最后一行（状态更新以追加覆盖行方式写入）
    final byId = <String, ChatMessage>{};
    final order = <String>[];
    for (final line in f.readAsLinesSync()) {
      if (line.trim().isEmpty) continue;
      try {
        final m =
            ChatMessage.fromJson(jsonDecode(line) as Map<String, dynamic>);
        if (byId.containsKey(m.id)) {
          byId[m.id] = m;
        } else {
          byId[m.id] = m;
          order.add(m.id);
        }
      } catch (_) {}
    }
    return [for (final id in order) byId[id]!];
  }

  Future<void> appendHistory(ChatMessage m) async {
    final f = _historyFile(m.peerId);
    await f.writeAsString('${jsonEncode(m.toJson())}\n',
        mode: FileMode.append, flush: true);
  }

  /// 覆盖写入整个会话（用于状态变更如发送成功/失败后同步）
  Future<void> rewriteHistory(String peerId, List<ChatMessage> msgs) async {
    final f = _historyFile(peerId);
    final buf = StringBuffer();
    for (final m in msgs) {
      buf.writeln(jsonEncode(m.toJson()));
    }
    await f.writeAsString(buf.toString(), flush: true);
  }

  Future<void> clearHistory(String peerId) async {
    final f = _historyFile(peerId);
    if (await f.exists()) await f.delete();
  }

  /// 列出所有存在历史记录的对端设备 id
  List<String> historyPeers() {
    if (!_historyDir.existsSync()) return [];
    return _historyDir
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('.jsonl'))
        .map((f) => p.basenameWithoutExtension(f.path))
        .toList();
  }
}
