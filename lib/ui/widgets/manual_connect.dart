import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../state/app_state.dart';

/// 手动按 IP 连接对话框：广播被过滤 / 跨网段时，直连对方 IP 的兜底入口。
Future<void> showManualConnectDialog(BuildContext context) async {
  final app = context.read<AppState>();
  if (!app.online) {
    ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请先上线（本机在线）后再手动连接')));
    return;
  }
  final controller = TextEditingController();
  final host = await showDialog<String>(
    context: context,
    builder: (_) => AlertDialog(
      icon: const Icon(Icons.lan_outlined),
      title: const Text('手动连接对方设备'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('输入对方设备的局域网 IP（可在对方「网络诊断」页看到）：',
              style: TextStyle(fontSize: 13)),
          const SizedBox(height: 10),
          TextField(
            controller: controller,
            autofocus: true,
            keyboardType: TextInputType.url,
            inputFormatters: [
              FilteringTextInputFormatter.allow(
                  RegExp(r'[0-9.]')),
            ],
            decoration: const InputDecoration(
              hintText: '例如 192.168.1.23',
              border: OutlineInputBorder(),
              isDense: true,
            ),
            onSubmitted: (v) => Navigator.of(context).pop(v),
          ),
        ],
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('取消')),
        FilledButton(
            onPressed: () => Navigator.of(context).pop(controller.text),
            child: const Text('连接')),
      ],
    ),
  );
  final target = (host ?? '').trim();
  if (target.isEmpty) return;

  if (!context.mounted) return;
  // 连接过程有网络往返，先给忙碌提示
  ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('正在连接 $target …'), duration: const Duration(seconds: 2)));
  final err = await app.connectManual(target);
  if (!context.mounted) return;
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(
      content: Text(err ?? '已连接 $target，对方设备现已出现在列表中'),
      duration: Duration(seconds: err == null ? 3 : 6),
    ));
}
