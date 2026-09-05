import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:pasteboard/pasteboard.dart';
import 'package:provider/provider.dart';
import 'package:window_manager/window_manager.dart';

import '../../services/screenshot_service.dart';
import '../../state/app_state.dart';

/// 底部输入区：文本输入、发送、粘贴图片、截图、选择文件。
/// - 桌面端可配置 Enter 发送 / Shift+Enter 换行（默认）；关闭时 Ctrl+Enter 发送。
/// - 移动端提供「+」入口：拍照发送 / 从相册选图发送。
/// - 输入框支持随字数自动增高，并可拖拽顶部手柄手动拉伸。
class InputBar extends StatefulWidget {
  const InputBar({super.key});

  @override
  State<InputBar> createState() => _InputBarState();
}

class _InputBarState extends State<InputBar> {
  final _controller = TextEditingController();
  final _focus = FocusNode();

  static const double _minHeight = 56;
  static const double _maxHeight = 260;
  double _inputHeight = 96;

  @override
  void dispose() {
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _sendText() {
    final text = _controller.text;
    if (text.trim().isEmpty) return;
    context.read<AppState>().sendText(text);
    _controller.clear();
    _focus.requestFocus();
  }

  /// 按键处理：Ctrl+V 智能粘贴；Enter/Ctrl+Enter 发送
  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }

    // Ctrl+V：剪贴板里是文件/图片就直接发送，是纯文本则粘进输入框（可继续编辑）
    if (HardwareKeyboard.instance.isControlPressed &&
        event.logicalKey == LogicalKeyboardKey.keyV) {
      _ctrlV();
      return KeyEventResult.handled;
    }

    final isEnter = event.logicalKey == LogicalKeyboardKey.enter ||
        event.logicalKey == LogicalKeyboardKey.numpadEnter;
    if (!isEnter) return KeyEventResult.ignored;

    final shift = HardwareKeyboard.instance.isShiftPressed;
    final ctrl = HardwareKeyboard.instance.isControlPressed;
    final enterToSend = context.read<AppState>().settings.enterToSend;

    if (enterToSend) {
      // Enter 发送；Shift+Enter 换行
      if (shift) return KeyEventResult.ignored;
      _sendText();
      return KeyEventResult.handled;
    } else {
      // Ctrl+Enter 发送；其余换行
      if (ctrl) {
        _sendText();
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }
  }

  /// 在光标处插入文本（替代系统粘贴，便于插入前先判断剪贴板内容类型）
  void _insertAtCursor(String text) {
    final v = _controller.value;
    final sel = v.selection.isValid
        ? v.selection
        : TextSelection.collapsed(offset: v.text.length);
    final start = sel.start.clamp(0, v.text.length);
    final end = sel.end.clamp(0, v.text.length);
    final newText = v.text.replaceRange(start, end, text);
    final caret = start + text.length;
    _controller.value = TextEditingValue(
      text: newText,
      selection: TextSelection.collapsed(offset: caret),
    );
  }

  /// Ctrl+V：文件 → 图片 → 文字（文字进输入框，不直接发）
  Future<void> _ctrlV() async {
    final app = context.read<AppState>();
    // 1. 剪贴板文件（资源管理器里复制的文件）
    try {
      final files = await Pasteboard.files();
      if (files.isNotEmpty) {
        var sent = false;
        for (final f in files) {
          try {
            if (await File(f).exists()) {
              await app.sendFilePath(f);
              sent = true;
            }
          } catch (_) {}
        }
        if (sent) return;
      }
    } catch (_) {}
    // 2. 剪贴板图片（网页/聊天软件里复制的图、截图）
    try {
      final img = await Pasteboard.image;
      if (img != null && img.isNotEmpty) {
        await app.sendImageBytes(img);
        return;
      }
    } catch (_) {}
    // 3. 纯文本：粘进输入框，让用户可以继续编辑再发
    final data = await Clipboard.getData('text/plain');
    final text = data?.text;
    if (text == null || text.isEmpty) {
      app.onNotice?.call('剪贴板是空的');
      return;
    }
    if (!mounted) return;
    _insertAtCursor(text);
    _focus.requestFocus();
  }

  Future<void> _pickFiles() async {
    final result = await FilePicker.pickFiles(allowMultiple: true);
    if (result == null || !mounted) return;
    final app = context.read<AppState>();
    for (final f in result.files) {
      if (f.path != null) await app.sendFilePath(f.path!);
    }
  }

  /// 移动端「+」：拍照 / 相册选图（可选原图或压缩）作为图片消息发送
  Future<void> _pickMedia() async {
    // photo(压缩) / photoOriginal(原图) / camera
    final choice = await showModalBottomSheet<String>(
      context: context,
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.photo_camera_outlined),
              title: const Text('拍照发送'),
              subtitle: const Text('自动压缩，适合随手拍',
                  style: TextStyle(fontSize: 12, color: Colors.black45)),
              onTap: () => Navigator.pop(context, 'camera'),
            ),
            ListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: const Text('从相册选择（压缩发送）'),
              subtitle: const Text('自动压缩，传输更快更省流量',
                  style: TextStyle(fontSize: 12, color: Colors.black45)),
              onTap: () => Navigator.pop(context, 'photo'),
            ),
            ListTile(
              leading: const Icon(Icons.filter_none_outlined),
              title: const Text('从相册选择（发送原图）'),
              subtitle: const Text('不压缩，保留原始画质',
                  style: TextStyle(fontSize: 12, color: Colors.black45)),
              onTap: () => Navigator.pop(context, 'photoOriginal'),
            ),
          ],
        ),
      ),
    );
    if (choice == null || !mounted) return;
    final app = context.read<AppState>();
    final picker = ImagePicker();
    try {
      if (choice == 'camera') {
        final x = await picker.pickImage(
            source: ImageSource.camera, maxWidth: 1920, imageQuality: 85);
        if (x == null || !mounted) return;
        final bytes = await x.readAsBytes();
        await app.sendImageBytes(bytes, name: x.name);
      } else {
        final original = choice == 'photoOriginal';
        final xs = original
            ? await picker.pickMultiImage()
            : await picker.pickMultiImage(maxWidth: 1920, imageQuality: 85);
        if (xs.isEmpty || !mounted) return;
        for (final x in xs) {
          final bytes = await x.readAsBytes();
          await app.sendImageBytes(bytes, name: x.name);
        }
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('无法获取图片，请重试')));
      }
    }
  }

  /// 桌面端内置截图并发送
  Future<void> _screenshot() async {
    final app = context.read<AppState>();
    // 先最小化本窗口，避免遮挡截图区域
    try {
      await windowManager.minimize();
      await Future.delayed(const Duration(milliseconds: 250));
    } catch (_) {}
    final bytes = await ScreenshotService.instance.captureRegion();
    try {
      await windowManager.restore();
    } catch (_) {}
    if (bytes != null) {
      await app.sendImageBytes(bytes,
          name: 'shot_${DateTime.now().millisecondsSinceEpoch}.png');
    }
  }

  @override
  Widget build(BuildContext context) {
    final enterToSend = context.select<AppState, bool>(
        (s) => s.settings.enterToSend);
    final isDesktop = !Platform.isAndroid && !Platform.isIOS;
    // 移动端无物理回车键概念，提示语不展示 Enter 说明
    final hint = isDesktop
        ? (enterToSend
            ? '输入消息，Enter 发送，Shift+Enter 换行'
            : '输入消息，Ctrl+Enter 发送')
        : '输入消息';
    final primary = Theme.of(context).colorScheme.primary;

    return Container(
      decoration: const BoxDecoration(
        color: Colors.white,
        border: Border(top: BorderSide(color: Color(0xFFE6E6E6))),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // 可拖拽拉伸手柄
          MouseRegion(
            cursor: SystemMouseCursors.resizeUpDown,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onVerticalDragUpdate: (d) {
                setState(() {
                  _inputHeight = (_inputHeight - d.delta.dy)
                      .clamp(_minHeight, _maxHeight);
                });
              },
              child: SizedBox(
                height: 12,
                child: Center(
                  child: Container(
                    width: 40,
                    height: 4,
                    decoration: BoxDecoration(
                      color: const Color(0xFFCCCCCC),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
              ),
            ),
          ),
          // 工具栏（剪贴板图片已由 Ctrl+V / 右键「粘贴发送」覆盖，不再单列按钮）
          Row(
            children: [
              const SizedBox(width: 4),
              if (isDesktop)
                IconButton(
                  tooltip: '截图发送（默认 Alt+A）',
                  icon: const Icon(Icons.crop),
                  onPressed: _screenshot,
                ),
              IconButton(
                tooltip: '发送文件',
                icon: const Icon(Icons.attach_file),
                onPressed: _pickFiles,
              ),
              if (!isDesktop)
                IconButton(
                  tooltip: '拍照或选择照片',
                  icon: const Icon(Icons.add_circle_outline),
                  onPressed: _pickMedia,
                ),
            ],
          ),
          // 输入框（可拉伸 + 自动增高）
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Expanded(
                  child: SizedBox(
                    height: _inputHeight,
                    child: Focus(
                      onKeyEvent: _onKey,
                      child: TextField(
                        controller: _controller,
                        focusNode: _focus,
                        maxLines: null,
                        expands: true,
                        textAlignVertical: TextAlignVertical.top,
                        keyboardType: TextInputType.multiline,
                        decoration: InputDecoration(
                          hintText: hint,
                          isDense: true,
                          filled: true,
                          fillColor: const Color(0xFFF2F3F5),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(20),
                            borderSide: BorderSide.none,
                          ),
                          enabledBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(20),
                            borderSide: BorderSide.none,
                          ),
                          focusedBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(20),
                            borderSide: BorderSide(color: primary, width: 1.5),
                          ),
                          contentPadding: const EdgeInsets.symmetric(
                              horizontal: 16, vertical: 12),
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                SizedBox(
                  height: 44,
                  child: FilledButton(
                    style: FilledButton.styleFrom(
                      shape: const StadiumBorder(),
                      padding: const EdgeInsets.symmetric(horizontal: 22),
                    ),
                    onPressed: _sendText,
                    child: const Text('发送'),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
