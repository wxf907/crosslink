import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pasteboard/pasteboard.dart';
import 'package:provider/provider.dart';
import 'package:super_clipboard/super_clipboard.dart' show DataReader;
import 'package:super_drag_and_drop/super_drag_and_drop.dart';

import '../../core/constants.dart';
import '../../state/app_state.dart';
import 'input_bar.dart';
import 'message_bubble.dart';

/// 中间消息主窗口：会话标题 + 消息列表 + 输入区。
/// - 拖拽文件/文字到消息区直接发送（类微信）
/// - 右键菜单「粘贴发送」：剪贴板里有文件/图片/文字均可直接发出
/// - Ctrl+V（输入框未聚焦时）同样智能粘贴发送
class ChatPanel extends StatefulWidget {
  const ChatPanel({super.key});

  @override
  State<ChatPanel> createState() => _ChatPanelState();
}

class _ChatPanelState extends State<ChatPanel> {
  final _scroll = ScrollController();
  bool _dragging = false;

  static bool get _isDesktop => !Platform.isAndroid && !Platform.isIOS;

  void _jumpBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.jumpTo(_scroll.position.maxScrollExtent);
      }
    });
  }

  // ---------------- 拖拽发送 ----------------

  /// 拖拽落点：文件 → 发文件；文字 → 发消息
  Future<void> _handleDrop(PerformDropEvent event) async {
    if (!mounted) return;
    setState(() => _dragging = false);
    final app = context.read<AppState>();
    for (final item in event.session.items) {
      final reader = item.dataReader;
      if (reader == null) continue;
      if (reader.canProvide(Formats.fileUri)) {
        final uri = await _readValue<Uri>(reader, Formats.fileUri);
        if (uri != null) {
          try {
            final path = uri.isScheme('file') ? uri.toFilePath() : '$uri';
            if (path.isNotEmpty) await app.sendFilePath(path);
          } catch (_) {}
        }
      } else if (reader.canProvide(Formats.plainText)) {
        final text = await _readValue<String>(reader, Formats.plainText);
        if (text != null && text.trim().isNotEmpty) {
          await app.sendText(text);
        }
      }
    }
  }

  /// 异步读取拖拽数据值（回调式 API 包装为 Future，附超时保护）
  Future<T?> _readValue<T extends Object>(
    DataReader reader,
    ValueFormat<T> format,
  ) async {
    final c = Completer<T?>();
    final progress = reader.getValue<T>(
      format,
      (v) {
        if (!c.isCompleted) c.complete(v);
      },
      onError: (_) {
        if (!c.isCompleted) c.complete(null);
      },
    );
    if (progress == null) return null; // 该格式实际不可用
    try {
      return await c.future.timeout(const Duration(seconds: 10));
    } on TimeoutException {
      return null;
    }
  }

  // ---------------- 粘贴发送 ----------------

  /// 智能粘贴：剪贴板里是文件就发文件，是图片就发图，是文字就发文字
  Future<void> _smartPaste(AppState app) async {
    // 1. 剪贴板文件（如在资源管理器中复制的文件）
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
    // 2. 剪贴板图片（如网页/聊天软件里复制的图）
    try {
      final img = await Pasteboard.image;
      if (img != null && img.isNotEmpty) {
        await app.sendImageBytes(img);
        return;
      }
    } catch (_) {}
    // 3. 剪贴板文字
    final data = await Clipboard.getData('text/plain');
    final text = data?.text;
    if (text != null && text.trim().isNotEmpty) {
      await app.sendText(text);
      return;
    }
    app.onNotice?.call('剪贴板中没有可发送的内容');
  }

  /// 右键菜单：粘贴发送
  /// 用「抬起」事件而非「按下」：按下事件不做互斥仲裁，
  /// 会与气泡自身的右键菜单同时弹出造成重叠
  Future<void> _showContextMenu(Offset globalPos) async {
    if (!_isDesktop) return;
    final app = context.read<AppState>();
    final overlay =
        Overlay.of(context).context.findRenderObject() as RenderBox?;
    if (overlay == null) return;
    final pos = globalPos;
    final position = RelativeRect.fromLTRB(
      pos.dx,
      pos.dy,
      overlay.size.width - pos.dx,
      overlay.size.height - pos.dy,
    );
    final v = await showMenu<String>(
      context: context,
      position: position,
      items: const [PopupMenuItem(value: 'paste', child: Text('粘贴发送'))],
    );
    if (v == 'paste') await _smartPaste(app);
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final peerId = app.activePeerId;
    if (peerId == null) {
      return const Center(
        child: Text(
          '选择左侧设备开始会话',
          style: TextStyle(color: Colors.black38, fontSize: 16),
        ),
      );
    }

    final peer = app.peers.where((p) => p.id == peerId).firstOrNull;
    final messages = app.messagesOf(peerId);
    _jumpBottom();

    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyV, control: true): () {
          // 输入框聚焦时 Ctrl+V 由文本框正常处理（粘贴为可编辑文本）
          if (_isDesktop && !_inputFieldFocused(app)) {
            _smartPaste(app);
          }
        },
      },
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onSecondaryTapUp: (d) => _showContextMenu(d.globalPosition),
        // 拖拽接收区覆盖整个面板（标题/消息/输入区）——
        // 类微信习惯是把文件拖到输入框，之前只覆盖消息区导致那里显示禁止符号
        child: DropRegion(
          formats: const [Formats.fileUri, Formats.plainText],
          hitTestBehavior: HitTestBehavior.opaque,
          onDropOver: (event) => DropOperation.copy,
          onDropEnter: (_) => setState(() => _dragging = true),
          onDropLeave: (_) => setState(() => _dragging = false),
          onDropEnded: (_) {
            if (mounted && _dragging) setState(() => _dragging = false);
          },
          onPerformDrop: _handleDrop,
          child: DecoratedBox(
            decoration: BoxDecoration(
              border: _dragging
                  ? Border.all(
                      color: Theme.of(context).colorScheme.primary, width: 2)
                  : null,
            ),
            child: Column(
              children: [
                // 会话标题栏
                Container(
                  height: 52,
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  decoration: const BoxDecoration(
                    color: Colors.white,
                    border: Border(
                      bottom: BorderSide(color: Color(0xFFE6E6E6)),
                    ),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        peer?.type == DeviceType.android
                            ? Icons.smartphone
                            : Icons.computer,
                        size: 20,
                        color: Colors.black54,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        peer?.name ?? '设备',
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Container(
                        width: 8,
                        height: 8,
                        decoration: BoxDecoration(
                          color: (peer?.online ?? false)
                              ? Colors.green
                              : ((peer?.unreachable ?? false)
                                  ? Colors.orange
                                  : Colors.grey),
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: 4),
                      Text(
                        (peer?.online ?? false)
                            ? '在线'
                            : ((peer?.unreachable ?? false)
                                ? '连不上（对方防火墙未放行）'
                                : '离线'),
                        style: TextStyle(
                          fontSize: 12,
                          color: (peer?.unreachable ?? false)
                              ? Colors.orange.shade800
                              : Colors.black45,
                        ),
                      ),
                      const Spacer(),
                      PopupMenuButton<String>(
                        onSelected: (v) {
                          if (v == 'clear') {
                            app.clearConversation(peerId);
                          }
                        },
                        itemBuilder: (_) => const [
                          PopupMenuItem(value: 'clear', child: Text('清空聊天记录')),
                        ],
                      ),
                    ],
                  ),
                ),
                // 消息列表（拖拽接收在整面板层，这里只保留高亮提示）
                Expanded(
                  child: Container(
                    color: _dragging
                        ? const Color(0xFFDCEEFB)
                        : const Color(0xFFF5F6F8),
                    child: Stack(
                      children: [
                        ListView.builder(
                          controller: _scroll,
                          padding: const EdgeInsets.symmetric(vertical: 10),
                          itemCount: messages.length,
                          itemBuilder: (_, i) =>
                              MessageBubble(msg: messages[i]),
                        ),
                        if (_dragging)
                          Center(
                            child: Text(
                              '松开即发送',
                              style: TextStyle(
                                fontSize: 18,
                                color: Theme.of(context).colorScheme.primary,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
                const InputBar(),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 输入框当前是否持有焦点（此时 Ctrl+V 交给文本框做普通粘贴）
  bool _inputFieldFocused(AppState app) {
    final ctx = FocusManager.instance.primaryFocus?.context;
    if (ctx == null) return false;
    // 焦点节点直接挂在 EditableTextState 的 context 上
    if (ctx is StatefulElement && ctx.state is EditableTextState) return true;
    return ctx.findAncestorStateOfType<EditableTextState>() != null;
  }
}

extension _FirstOrNull<E> on Iterable<E> {
  E? get firstOrNull => isEmpty ? null : first;
}
