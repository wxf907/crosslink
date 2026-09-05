import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../core/logger.dart';

/// 运行日志页（设置 → 诊断 → 运行日志）
class LogsPage extends StatelessWidget {
  const LogsPage({super.key});

  Color _color(String level) {
    switch (level) {
      case 'E':
        return Colors.red;
      case 'W':
        return Colors.orange;
      default:
        return Colors.black54;
    }
  }

  @override
  Widget build(BuildContext context) {
    final logs = context.watch<LogService>();
    final entries = logs.entries.reversed.toList();
    return Scaffold(
      appBar: AppBar(
        title: const Text('运行日志'),
        actions: [
          IconButton(
            tooltip: '复制全部',
            icon: const Icon(Icons.copy),
            onPressed: () {
              Clipboard.setData(ClipboardData(text: logs.exportText()));
              ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('日志已复制到剪贴板')));
            },
          ),
          IconButton(
            tooltip: '清空',
            icon: const Icon(Icons.delete_outline),
            onPressed: logs.clear,
          ),
        ],
      ),
      body: entries.isEmpty
          ? const Center(child: Text('暂无日志', style: TextStyle(color: Colors.black38)))
          : ListView.separated(
              padding: const EdgeInsets.all(8),
              itemCount: entries.length,
              separatorBuilder: (_, _) => const Divider(height: 1),
              itemBuilder: (_, i) {
                final e = entries[i];
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 4),
                  child: Text(
                    e.toString(),
                    style: TextStyle(
                        fontSize: 12,
                        fontFamily: 'monospace',
                        color: _color(e.level)),
                  ),
                );
              },
            ),
    );
  }
}
