import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:screen_capturer/screen_capturer.dart';

import '../core/logger.dart';

/// 桌面端内置截图服务：调用系统区域截图，返回图片字节。
class ScreenshotService {
  ScreenshotService._();
  static final ScreenshotService instance = ScreenshotService._();

  bool _capturing = false;

  /// 区域截图。返回 PNG 字节；用户取消或失败返回 null。
  Future<Uint8List?> captureRegion() async {
    if (_capturing) return null; // 防止快捷键连触发
    _capturing = true;
    try {
      final dir = await getTemporaryDirectory();
      final path = p.join(
          dir.path, 'shot_${DateTime.now().millisecondsSinceEpoch}.png');
      final data = await screenCapturer.capture(
        mode: CaptureMode.region,
        imagePath: path,
        copyToClipboard: false,
      );
      if (data?.imageBytes != null) {
        return data!.imageBytes;
      }
      // 部分平台仅落地文件，未回传字节
      final f = File(path);
      if (await f.exists()) {
        final bytes = await f.readAsBytes();
        if (bytes.isNotEmpty) return bytes;
      }
      return null;
    } catch (e) {
      log.w('Shot', '截图失败: $e');
      return null;
    } finally {
      _capturing = false;
    }
  }
}
