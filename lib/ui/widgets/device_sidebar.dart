import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/constants.dart';
import '../../state/app_state.dart';
import '../contact_author.dart';
import '../settings_page.dart';
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
            child: Text('我的设备（在线 $onlineCount）',
                style: const TextStyle(
                    fontSize: 12, color: Colors.black54)),
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
                      return Container(
                        color: active ? const Color(0xFFDCEEFB) : null,
                        child: ListTile(
                          dense: true,
                          leading: Stack(
                            children: [
                              CircleAvatar(
                                radius: 18,
                                backgroundColor: Colors.white,
                                child: Icon(
                                  p.type == DeviceType.android
                                      ? Icons.smartphone
                                      : Icons.computer,
                                  color: Colors.black54,
                                ),
                              ),
                              Positioned(
                                right: 0,
                                bottom: 0,
                                child: Container(
                                  width: 10,
                                  height: 10,
                                  decoration: BoxDecoration(
                                    color: p.online
                                        ? Colors.green
                                        : (p.unreachable
                                            ? Colors.orange
                                            : Colors.grey),
                                    shape: BoxShape.circle,
                                    border: Border.all(
                                        color: Colors.white, width: 1.5),
                                  ),
                                ),
                              ),
                            ],
                          ),
                          title: Text(p.name,
                              maxLines: 1, overflow: TextOverflow.ellipsis),
                          subtitle: Text(
                              '${p.type.label} · '
                              '${p.online ? "在线" : (p.unreachable ? "连不上(对方防火墙)" : "离线")}',
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
                          onLongPress: !p.online
                              ? () => _confirmDeletePeer(context, app, p.id, p.name)
                              : null,
                        ),
                      );
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
              const ContactEntryButton(),
              const SizedBox(width: 8),
            ],
          ),
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
