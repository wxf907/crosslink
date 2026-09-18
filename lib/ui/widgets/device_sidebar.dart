import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../state/app_state.dart';
import '../contact_author.dart';
import '../print_service_page.dart';
import '../settings_page.dart';
import 'device_avatar.dart';
import 'manual_connect.dart';

class DeviceSidebar extends StatelessWidget {
  /// 选择设备后的回调（移动端用于跳转到会话页）
  final void Function(String peerId)? onOpenPeer;
  const DeviceSidebar({super.key, this.onOpenPeer});

  /// 长按删除离线设备：确认后清除聊天记录和缓存
  Future<void> _confirmDeletePeer(
      BuildContext context, AppState app, String peerId, String name) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除设备'),
        content: Text('确定要删除离线设备「$name」吗？\n该设备的聊天记录将被清除。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('删除')),
        ],
      ),
    );
    if (confirmed == true) {
      await app.deletePeer(peerId);
    }
  }

  /// 副标题：`IP尾段 · 最近动态 [· 状态]`。
  ///
  /// 在线状态已由头像外圈描边表达，在线时不再重复写"在线"，
  /// 把这一行留给真正有用的"谁在什么时候给我发了什么"；
  /// 只有异常态（连不上/离线）才补状态词。什么信息都没有时回退类型名。
  static String _subtitle(PeerView p) {
    final now = DateTime.now();
    final activity = p.activityLabel(now);
    final parts = <String>[
      if (p.ipTail.isNotEmpty) p.ipTail,
      if (activity.isNotEmpty) activity,
      if (!p.online) (p.unreachable ? '连接不稳定' : '离线'),
    ];
    if (parts.isEmpty) return p.type.label;
    return parts.join(' · ');
  }

  /// 设备菜单项：图标 + 文字的紧凑排布
  static PopupMenuItem<String> _menuItem(
      String value, IconData icon, String text) {
    return PopupMenuItem<String>(
      value: value,
      child: Row(
        children: [
          Icon(icon, size: 18, color: Colors.black54),
          const SizedBox(width: 10),
          Flexible(
              child: Text(text, maxLines: 1, overflow: TextOverflow.ellipsis)),
        ],
      ),
    );
  }

  /// 设备菜单：长按（移动端）与右键（桌面端）共用。
  Future<void> _showPeerMenu(
      BuildContext context, AppState app, PeerView p) async {
    final box = context.findRenderObject();
    RelativeRect anchor = RelativeRect.fill;
    if (box is RenderBox) {
      final off = box.localToGlobal(Offset.zero);
      final mid = off.dy + box.size.height / 2;
      anchor = RelativeRect.fromLTRB(off.dx, mid, off.dx + box.size.width, mid);
    }
    final choice = await showMenu<String>(
      context: context,
      position: anchor,
      items: [
        _menuItem('alias', Icons.edit_note,
            p.alias.isEmpty ? '设置备注名' : '修改备注名（当前：${p.alias}）'),
        if (p.alias.isNotEmpty)
          _menuItem('clear', Icons.clear, '清除备注名'),
        if (!p.online) _menuItem('delete', Icons.delete_outline, '删除设备'),
      ],
    );
    if (!context.mounted || choice == null) return;
    switch (choice) {
      case 'alias':
        await _editAlias(context, app, p);
      case 'clear':
        await app.setPeerAlias(p.id, '');
      case 'delete':
        await _confirmDeletePeer(context, app, p.id, p.displayName);
    }
  }

  /// 备注名输入框：只存本机，不影响对方那台机器的自报名。
  Future<void> _editAlias(
      BuildContext context, AppState app, PeerView p) async {
    final controller = TextEditingController(text: p.alias);
    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('设置备注名'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('对方自报名：${p.name}'),
            const SizedBox(height: 10),
            TextField(
              controller: controller,
              autofocus: true,
              maxLength: 20,
              decoration: const InputDecoration(
                hintText: '例如：财务小王的机器 / 会议室主机',
                counterText: '',
                border: OutlineInputBorder(),
                isDense: true,
              ),
            ),
            const SizedBox(height: 6),
            const Text(
              '备注名只在你这台机器上显示，不会改动对方的设备名。',
              style: TextStyle(fontSize: 11, color: Colors.black45),
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('保存')),
        ],
      ),
    );
    if (saved == true) {
      await app.setPeerAlias(p.id, controller.text);
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final peers = app.peers;
    final onlineCount = peers.where((p) => p.online).length;

    return Container(
      color: const Color(0xFFECEDEF),
      child: Column(
        children: [
          // 顶部：账号信息 + 在线状态
          Container(
            padding: const EdgeInsets.fromLTRB(14, 14, 8, 12),
            color: Theme.of(context).colorScheme.primary,
            child: Row(
              children: [
                _AccountAvatar(path: app.identity?.avatarPath, radius: 20),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(app.identity?.accountId ?? '',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.bold)),
                      Text(app.online ? '在线 · 本机：${app.identity?.deviceName ?? ''}' : '离线',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              color: Colors.white70, fontSize: 12)),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: '手动连接对方 IP',
                  icon: const Icon(Icons.add, color: Colors.white),
                  onPressed: () => showManualConnectDialog(context),
                ),
                IconButton(
                  tooltip: '刷新设备',
                  icon: const Icon(Icons.refresh, color: Colors.white),
                  onPressed: app.refresh,
                ),
              ],
            ),
          ),
          // 分组标题
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            child: Text.rich(
              TextSpan(
                text: '我的设备（在线 $onlineCount',
                style: const TextStyle(fontSize: 12, color: Colors.black54),
                children: [
                  if (app.totalUnread > 0)
                    TextSpan(
                      text: ' · 未读 ${app.totalUnread}',
                      style: const TextStyle(
                          color: Color(0xFFE5484D),
                          fontWeight: FontWeight.w600),
                    ),
                  const TextSpan(text: '）'),
                ],
              ),
            ),
          ),
          // 设备列表
          Expanded(
            child: peers.isEmpty
                ? const Center(
                    child: Padding(
                      padding: EdgeInsets.all(16),
                      child: Text('暂无其他设备\n请在同一账号、同一局域网下登录其他设备',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: Colors.black38)),
                    ),
                  )
                : ListView.builder(
                    itemCount: peers.length,
                    itemBuilder: (_, i) {
                      final p = peers[i];
                      final selected = app.selected.contains(p.id);
                      final active = app.activePeerId == p.id;
                      // Builder 让 context 指向这一行本身，
                      // 菜单才能锚定到被点击的那一行（外层 context 会跑到列表左上角）
                      return Builder(builder: (rowContext) {
                        return Container(
                          color: active ? const Color(0xFFDCEEFB) : null,
                          // ListTile 没有 onSecondaryTap，用一层 translucent 的
                          // GestureDetector 承接桌面右键，不影响它自身的点击与长按
                          child: GestureDetector(
                            onSecondaryTap: () =>
                                _showPeerMenu(rowContext, app, p),
                            behavior: HitTestBehavior.translucent,
                            child: ListTile(
                              dense: true,
                              leading: DeviceAvatar(peer: p),
                              title: Text(p.displayName,
                                  maxLines: 1, overflow: TextOverflow.ellipsis),
                              subtitle: Text(_subtitle(p),
                                  style: TextStyle(
                                      fontSize: 11,
                                      color: p.unreachable
                                          ? Colors.orange.shade800
                                          : null)),
                              trailing: p.online
                                  ? Checkbox(
                                      value: selected,
                                      onChanged: (_) => app.toggleSelect(p.id),
                                    )
                                  : (p.unreachable
                                      ? const Icon(Icons.portable_wifi_off,
                                          size: 18, color: Colors.orange)
                                      : null),
                              onTap: () {
                                app.selectPeer(p.id);
                                onOpenPeer?.call(p.id);
                              },
                              // 长按（移动端）与右键（桌面端）走同一个设备菜单
                              onLongPress: () =>
                                  _showPeerMenu(rowContext, app, p),
                            ),
                          ),
                        );
                      });
                    },
                  ),
          ),
          // 多选群发提示
          if (app.selected.isNotEmpty)
            Container(
              width: double.infinity,
              color: const Color(0xFFDCEEFB),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
              child: Text('已选 ${app.selected.length} 台设备，发送将群发',
                  style: const TextStyle(fontSize: 12)),
            ),
          // 底部：左「设置」右「联系」——两端同一位置，保持心智一致
          const Divider(height: 1),
          Row(
            children: [
              Expanded(
                child: ListTile(
                  leading: const Icon(Icons.settings),
                  title: const Text('设置'),
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const SettingsPage()),
                  ),
                ),
              ),
              if (Platform.isWindows) const PrintEntryButton(),
              const ContactEntryButton(),
              const SizedBox(width: 8),
            ],
          ),
        ],
      ),
    );
  }
}

/// 首页「打印」入口（仅 Windows）：直达打印服务页，带服务状态点
class PrintEntryButton extends StatelessWidget {
  const PrintEntryButton({super.key});

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    // 状态灯反映"打印机已对外共享"（SMB 为主，IPP 开启也算），
    // 而非旧的 IPP 开关——否则 IPP 默认关闭时灯永远灰，误导用户
    final color = (app.smbShared || app.settings.printEnabled)
        ? Colors.green
        : Colors.grey;
    return TextButton(
      onPressed: () => Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => const PrintServicePage()),
      ),
      style: TextButton.styleFrom(
        foregroundColor: Colors.black54,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        minimumSize: Size.zero,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 5),
          const Text('打印', style: TextStyle(fontSize: 13)),
        ],
      ),
    );
  }
}

/// 账号头像：有自定义头像则显示图片，否则默认图标
class _AccountAvatar extends StatelessWidget {
  final String? path;
  final double radius;
  const _AccountAvatar({required this.path, required this.radius});

  @override
  Widget build(BuildContext context) {
    final p = path;
    if (p != null && p.isNotEmpty && File(p).existsSync()) {
      return CircleAvatar(
        radius: radius,
        backgroundColor: Colors.white,
        backgroundImage: FileImage(File(p)),
      );
    }
    return CircleAvatar(
      radius: radius,
      backgroundColor: Colors.white,
      child: Icon(Icons.person, color: Theme.of(context).colorScheme.primary),
    );
  }
}
