import 'dart:io';

import 'package:flutter/services.dart';

import '../core/logger.dart';

/// 发布到公共目录后的结果
class PublicFile {
  final String path;
  final String uri;
  final String dir;
  final String name;
  const PublicFile({
    required this.path,
    required this.uri,
    required this.dir,
    required this.name,
  });

  /// 给用户看的友好位置名（避免露出 /storage/emulated/0/... 这种原始路径）
  String get friendlyDir {
    if (dir.contains('/Pictures/')) return '相册/CrossLink';
    if (dir.contains('/Movies/')) return '视频/CrossLink';
    if (dir.contains('/Download/')) return '下载/CrossLink';
    if (dir.contains('/Documents/')) return '文档/CrossLink';
    if (dir.contains('/Android/data/')) return '应用内';
    return dir.isEmpty ? '手机存储' : dir;
  }
}

/// 安卓：把收到的文件从应用缓存"发布"到公共目录（MediaStore，零权限）。
///
/// 图片 → 相册 Pictures/CrossLink；其它 → 下载 Download/CrossLink。
/// 落在公共目录后，任何品牌的文件管理器都能看到，"打开所在位置"自然成立，
/// 也不再需要 MANAGE_EXTERNAL_STORAGE 这类会触发权限重置的敏感权限。
class AndroidPublicStore {
  AndroidPublicStore._();

  static const _channel =
      MethodChannel('com.crosslink.crosslink/file_utils');

  static bool get supported => Platform.isAndroid;

  /// 返回 null 表示失败或系统不支持（Android 10 以下），调用方应保留缓存路径
  static Future<PublicFile?> publish(
    String cachePath,
    String fileName, {
    required bool image,
    bool move = true,
  }) async {
    if (!supported) return null;
    try {
      final r = await _channel.invokeMethod<Map<dynamic, dynamic>>(
        'publishToPublic',
        {
          'path': cachePath,
          'fileName': fileName,
          'kind': image ? 'image' : 'file',
          'move': move,
        },
      );
      if (r == null) return null;
      final path = r['path'] as String?;
      if (path == null || path.isEmpty) return null;
      final pf = PublicFile(
        path: path,
        uri: (r['uri'] as String?) ?? '',
        dir: (r['dir'] as String?) ?? '',
        name: (r['name'] as String?) ?? fileName,
      );
      log.i('Public', '已发布到公共目录: ${pf.path}');
      return pf;
    } on PlatformException catch (e) {
      log.w('Public', '发布失败 ${e.code}: ${e.message}');
      return null;
    } catch (e) {
      log.w('Public', '发布异常: $e');
      return null;
    }
  }

  /// 用系统文件管理器打开目录（多策略，失败返回 false）
  static Future<bool> openFolder(String path) async {
    if (!supported) return false;
    try {
      final ok = await _channel
          .invokeMethod<bool>('openFolder', {'path': path});
      return ok ?? false;
    } on PlatformException catch (e) {
      log.w('Public', '打开目录失败 ${e.code}: ${e.message}');
      return false;
    } catch (_) {
      return false;
    }
  }

  /// SAF 另存为（用户选位置，零权限）
  static Future<bool> saveAs(String path, String fileName) async {
    if (!supported) return false;
    try {
      final ok = await _channel.invokeMethod<bool>(
          'saveAs', {'path': path, 'fileName': fileName});
      return ok ?? false;
    } on PlatformException {
      return false;
    } catch (_) {
      return false;
    }
  }
}
