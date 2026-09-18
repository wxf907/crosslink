import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

/// Windows 任务栏按钮闪烁（FlashWindowEx）。
///
/// 用途：收到消息但窗口不在前台时，让任务栏上的 CrossLink 图标闪烁，
/// 把"哪台机器找过我"从软件内部提示升级成系统级提醒。
/// 用户点回窗口即停止（见 [stop]，由 main.dart 的焦点回调驱动）。
///
/// 刻意不引入 win32 包：这里只需要一个 API，手写 FFI 绑定比多拉一个
/// 依赖更划算（安卓端也完全不受影响，所有入口都有 [supported] 保护）。
class TaskbarFlash {
  TaskbarFlash._();

  static const int _flashStop = 0x00000000;
  static const int _flashAll = 0x00000003; // 标题栏 + 任务栏按钮
  static const int _flashTimerNoFg = 0x0000000C; // 一直闪到窗口到前台

  /// 仅 Windows 支持；其它平台调用会被静默忽略
  static bool get supported => Platform.isWindows;

  static _FlashWindowExDart? _fn;
  static bool _tried = false;

  static _FlashWindowExDart? get _api {
    if (_tried) return _fn;
    _tried = true;
    if (!supported) return null;
    try {
      _fn = DynamicLibrary.open('user32.dll')
          .lookupFunction<_FlashWindowExNative, _FlashWindowExDart>(
              'FlashWindowEx');
    } catch (_) {
      _fn = null; // 极端环境（user32 不可用）下不影响主流程
    }
    return _fn;
  }

  /// 开始闪烁，直到 [stop] 或窗口回到前台。
  /// [hwnd] 取自 `windowManager.getId()`——window_manager 在 Windows 上
  /// 返回的就是主窗口句柄。
  static void start(int hwnd) =>
      _apply(hwnd, _flashAll | _flashTimerNoFg, 0, 0);

  /// 停止闪烁
  static void stop(int hwnd) => _apply(hwnd, _flashStop, 0, 0);

  static void _apply(int hwnd, int flags, int count, int timeout) {
    final api = _api;
    if (api == null || hwnd == 0) return;
    final info = calloc<FlashInfo>();
    try {
      info.ref.cbSize = sizeOf<FlashInfo>();
      info.ref.hwnd = Pointer.fromAddress(hwnd);
      info.ref.dwFlags = flags;
      info.ref.uCount = count;
      info.ref.dwTimeout = timeout;
      api(info);
    } finally {
      calloc.free(info);
    }
  }
}

/// WINUSER.h 的 FLASHWINFO。
///
/// 字段顺序与类型必须与 C 结构一致：x64 下 Dart FFI 会自动按 8 字节对齐
/// hwnd，得到与 C 编译器相同的 28 字节布局（cbSize 后补 4 字节填充）。
final class FlashInfo extends Struct {
  @Uint32()
  external int cbSize;

  external Pointer<Void> hwnd;

  @Uint32()
  external int dwFlags;

  @Uint32()
  external int uCount;

  @Uint32()
  external int dwTimeout;
}

typedef _FlashWindowExNative = Int32 Function(Pointer<FlashInfo>);
typedef _FlashWindowExDart = int Function(Pointer<FlashInfo>);
