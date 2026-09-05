import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:open_filex/open_filex.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/constants.dart';
import '../../core/format.dart';
import '../../models/message.dart';
import '../../models/transfer_task.dart';
import '../../state/app_state.dart';

/// 原生文件管理器通道（仅 Android 使用）
const _fileUtilsChannel = MethodChannel('com.crosslink.crosslink/file_utils');

/// 单条消息气泡（文本 / 图片 / 文件）。
/// 图片与文件气泡：桌面端右键、移动端长按弹出菜单
/// （打开文件 / 打开所在位置 / 复制文件路径）。
class MessageBubble extends StatelessWidget {
  final ChatMessage msg;
  const MessageBubble({super.key, required this.msg});

  @override
  Widget build(BuildContext context) {
    final out = msg.outgoing;
    final align = out ? CrossAxisAlignment.end : CrossAxisAlignment.start;
    final bubbleColor =
        out ? Theme.of(context).colorScheme.primary : Colors.white;
    final textColor = out ? Colors.white : Colors.black87;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
      child: Column(
        crossAxisAlignment: align,
        children: [
          Row(
            mainAxisAlignment: out
                ? MainAxisAlignment.end
                : MainAxisAlignment.start,
            children: [
              Text(
                out ? '我' : msg.fromName,
                style: const TextStyle(fontSize: 11, color: Colors.black45),
              ),
              const SizedBox(width: 6),
              Text(
                Fmt.msgTime(msg.time),
                style: const TextStyle(fontSize: 11, color: Colors.black38),
              ),
            ],
          ),
          const SizedBox(height: 3),
          Row(
            mainAxisAlignment: out
                ? MainAxisAlignment.end
                : MainAxisAlignment.start,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              if (out && msg.status == MessageStatus.sending)
                const Padding(
                  padding: EdgeInsets.only(right: 6),
                  child: SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ),
              if (out && msg.status == MessageStatus.failed)
                IconButton(
                  tooltip: '重发',
                  icon: const Icon(Icons.error, color: Colors.red, size: 20),
                  onPressed: () => context.read<AppState>().retryMessage(msg),
                ),
              Flexible(
                child: Container(
                  constraints: const BoxConstraints(maxWidth: 420),
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: bubbleColor,
                    borderRadius: BorderRadius.circular(10),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.05),
                        blurRadius: 4,
                      ),
                    ],
                  ),
                  child: _content(context, textColor),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _content(BuildContext context, Color textColor) {
    switch (msg.kind) {
      case MessageKind.text:
      case MessageKind.system:
        return SelectableText(
          msg.text ?? '',
          style: TextStyle(color: textColor, fontSize: 15),
        );
      case MessageKind.image:
        // 尊重“图片自动预览”设置：关闭时降级为文件卡片
        final preview = context.select<AppState, bool>(
          (s) => s.settings.imagePreview,
        );
        return preview ? _image(context) : _file(context);
      case MessageKind.file:
        return _file(context);
    }
  }

  // ---------------- 文件/图片右键与长按菜单 ----------------

  bool get _hasLocalFile =>
      msg.localPath != null && File(msg.localPath!).existsSync();

  /// 桌面端：右键菜单
  Future<void> _showDesktopMenu(
    BuildContext context, {
    Offset? position,
  }) async {
    if (!_hasLocalFile) return;
    final RenderBox? box = context.findRenderObject() as RenderBox?;
    final overlay =
        Overlay.of(context).context.findRenderObject() as RenderBox?;
    if (box == null || overlay == null) return;
    final pos = position ?? box.localToGlobal(Offset(box.size.width / 2, 0));
    final rel = RelativeRect.fromLTRB(
      pos.dx,
      pos.dy,
      overlay.size.width - pos.dx,
      overlay.size.height - pos.dy,
    );
    final v = await showMenu<String>(
      context: context,
      position: rel,
      items: const [
        PopupMenuItem(value: 'open', child: Text('打开文件')),
        PopupMenuItem(value: 'locate', child: Text('打开所在位置')),
        PopupMenuItem(value: 'copy', child: Text('复制文件路径')),
      ],
    );
    if (!context.mounted) return;
    await _handleMenuAction(context, v);
  }

  /// 移动端：长按底部菜单
  Future<void> _showMobileSheet(BuildContext context) async {
    if (!_hasLocalFile) return;
    final v = await showModalBottomSheet<String>(
      context: context,
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.all(12),
              child: Text(
                msg.fileName ?? '文件',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 12, color: Colors.black45),
              ),
            ),
            ListTile(
              leading: const Icon(Icons.open_in_new),
              title: const Text('打开文件'),
              onTap: () => Navigator.pop(context, 'open'),
            ),
            ListTile(
              leading: const Icon(Icons.folder_open),
              title: const Text('打开所在位置'),
              onTap: () => Navigator.pop(context, 'locate'),
            ),
            ListTile(
              leading: const Icon(Icons.ios_share),
              title: const Text('分享给其他应用'),
              subtitle: const Text('微信 / 网盘 / 蓝牙，也可借此另存',
                  style: TextStyle(fontSize: 12, color: Colors.black54)),
              onTap: () => Navigator.pop(context, 'share'),
            ),
            ListTile(
              leading: const Icon(Icons.drive_folder_upload),
              title: const Text('另存到其他位置'),
              subtitle: const Text('自选文件夹保存一份副本',
                  style: TextStyle(fontSize: 12, color: Colors.black54)),
              onTap: () => Navigator.pop(context, 'saveAs'),
            ),
          ],
        ),
      ),
    );
    if (!context.mounted) return;
    await _handleMenuAction(context, v);
  }

  Future<void> _handleMenuAction(BuildContext context, String? v) async {
    final path = msg.localPath;
    if (v == null || path == null || !_hasLocalFile) return;
    switch (v) {
      case 'open':
        await OpenFilex.open(path);
        break;
      case 'locate':
        await _openLocation(context, path);
        break;
      case 'copy':
        await Clipboard.setData(ClipboardData(text: path));
        if (context.mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('文件路径已复制')));
        }
        break;
      case 'share':
        try {
          await SharePlus.instance.share(
            ShareParams(
              files: [XFile(path)],
              subject: msg.fileName,
              text: msg.fileName,
            ),
          );
        } catch (e) {
          if (context.mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text('分享失败：$e')));
          }
        }
        break;
      case 'saveAs':
        if (Platform.isAndroid) {
          try {
            await _fileUtilsChannel.invokeMethod<bool>('saveAs', {
              'path': path,
              'fileName': msg.fileName ?? 'file',
            });
            if (context.mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('已保存到所选位置')));
            }
          } on PlatformException catch (e) {
            if (e.code != 'cancelled' && context.mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('保存失败：${e.message}')));
            }
          }
        } else if (Platform.isWindows) {
          // Windows: 用 explorer 打开保存目录让用户自行操作
          await Process.run('explorer.exe', ['/select,', path]);
        }
        break;
    }
  }

  /// 打开文件所在目录
  /// - Windows: explorer /select 打开目录并选中文件
  /// - Android: 通过 MethodChannel 调原生 Intent 打开文件管理器并定位到目录
  Future<void> _openLocation(BuildContext context, String path) async {
    final dir = File(path).parent.path;
    try {
      if (Platform.isWindows) {
        // explorer /select 打开目录并选中文件
        await Process.run('explorer.exe', ['/select,', path]);
        return;
      }
      // Android：先尝试通过 MethodChannel 打开目录（不分私有/公共路径），
      // 让能打开的系统自己打开，不能打开的再给提示
      if (Platform.isAndroid) {
        try {
          await _fileUtilsChannel
              .invokeMethod<bool>('openFolder', {'path': dir});
          return;
        } on PlatformException catch (e) {
          if (e.code == 'no_app') {
            if (context.mounted) {
              // 私有目录路径给专门的提示
              if (path.contains('/Android/data/')) {
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                    content: Text('此文件在应用私有目录里，当前手机的系统'
                        '禁止文件管理器访问。如需打开所在位置，请到 设置 → '
                        '文件接收保存目录 改为「下载」等公共目录后重新接收文件。')));
              } else {
                ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('未找到文件管理器应用')));
              }
            }
            return;
          }
          // 其他错误：回退到 OpenFilex
        }
      }
      // 非 Android 或回退：用 OpenFilex 打开目录
      final r = await OpenFilex.open(dir);
      if (r.type != ResultType.done && context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('没有可打开文件夹的应用，路径：$dir')));
      }
    } catch (_) {}
  }

  Widget _image(BuildContext context) {
    final path = msg.localPath;
    if (path == null || !File(path).existsSync()) {
      return const Text('[图片]');
    }
    return GestureDetector(
      onTap: () => _openImageViewer(context, path),
      // 用「抬起」而非「按下」：避免与聊天面板的右键菜单同时弹出
      onSecondaryTapUp: AppConst.isDesktop
          ? (d) => _showDesktopMenu(context, position: d.globalPosition)
          : null,
      onLongPress: AppConst.isMobile ? () => _showMobileSheet(context) : null,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(6),
        child: Image.file(
          File(path),
          width: 180,
          fit: BoxFit.cover,
          filterQuality: FilterQuality.low,
        ),
      ),
    );
  }

  /// 应用内全屏图片预览（支持缩放、保存/打开）
  void _openImageViewer(BuildContext context, String path) {
    Navigator.of(context).push(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => Scaffold(
          backgroundColor: Colors.black,
          appBar: AppBar(
            backgroundColor: Colors.black,
            foregroundColor: Colors.white,
            title: Text(msg.fileName ?? '图片'),
            actions: [
              IconButton(
                tooltip: '用系统程序打开',
                icon: const Icon(Icons.open_in_new),
                onPressed: () => OpenFilex.open(path),
              ),
            ],
          ),
          body: Center(
            child: InteractiveViewer(
              maxScale: 5,
              child: Image.file(File(path)),
            ),
          ),
        ),
      ),
    );
  }

  Widget _file(BuildContext context) {
    final app = context.watch<AppState>();
    // 关联进行中的传输任务
    TransferTask? task;
    for (final t in app.transfers.values) {
      if (t.messageId == msg.id) {
        task = t;
        break;
      }
    }
    final transferring =
        task != null && task.state == TransferState.transferring;
    final out = msg.outgoing;

    return GestureDetector(
      // 用「抬起」而非「按下」：避免与聊天面板的右键菜单同时弹出
      onSecondaryTapUp: AppConst.isDesktop
          ? (d) => _showDesktopMenu(context, position: d.globalPosition)
          : null,
      onLongPress: AppConst.isMobile ? () => _showMobileSheet(context) : null,
      child: InkWell(
        onTap: () {
          if (msg.localPath != null && File(msg.localPath!).existsSync()) {
            OpenFilex.open(msg.localPath!);
          }
        },
        child: SizedBox(
          width: 240,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    Icons.insert_drive_file,
                    color: out
                        ? Colors.white
                        : Theme.of(context).colorScheme.primary,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      msg.fileName ?? '文件',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: out ? Colors.white : Colors.black87,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                Fmt.size(msg.fileSize ?? 0),
                style: TextStyle(
                  fontSize: 12,
                  color: out ? Colors.white70 : Colors.black45,
                ),
              ),
              if (transferring) ...[
                const SizedBox(height: 6),
                LinearProgressIndicator(value: task.progress),
                const SizedBox(height: 2),
                Text(
                  '${(task.progress * 100).toStringAsFixed(0)}%  '
                  '${Fmt.speed(task.bytesPerSecond)}  剩余${Fmt.eta(task.etaSeconds)}',
                  style: TextStyle(
                    fontSize: 11,
                    color: out ? Colors.white70 : Colors.black45,
                  ),
                ),
              ],
              if (!out && msg.status == MessageStatus.received)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    '已保存 · 点击打开',
                    style: TextStyle(
                      fontSize: 11,
                      color: out ? Colors.white70 : Colors.green,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
