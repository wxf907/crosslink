import 'package:flutter/material.dart';
import 'package:hotkey_manager/hotkey_manager.dart';
import 'package:provider/provider.dart';

import '../services/hotkey_service.dart';
import '../state/app_state.dart';

/// 截图快捷键自定义页：用 HotKeyRecorder 录制新组合键并持久化。
class HotkeySettingsPage extends StatefulWidget {
  const HotkeySettingsPage({super.key});

  @override
  State<HotkeySettingsPage> createState() => _HotkeySettingsPageState();
}

class _HotkeySettingsPageState extends State<HotkeySettingsPage> {
  HotKey? _recorded;

  @override
  Widget build(BuildContext context) {
    final app = context.read<AppState>();
    final current = HotkeyService.instance.resolve(app.settings.screenshotHotkey);

    return Scaffold(
      appBar: AppBar(title: const Text('截图快捷键')),
      body: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('当前快捷键',
                style: TextStyle(color: Colors.black54, fontSize: 13)),
            const SizedBox(height: 6),
            Text(current.debugName,
                style: const TextStyle(
                    fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 28),
            const Text('录制新的快捷键（按下组合键）',
                style: TextStyle(color: Colors.black54, fontSize: 13)),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                border: Border.all(color: const Color(0xFFDDDDDD)),
                borderRadius: BorderRadius.circular(8),
              ),
              child: HotKeyRecorder(
                initalHotKey: current,
                onHotKeyRecorded: (hotKey) {
                  setState(() => _recorded = hotKey);
                },
              ),
            ),
            const SizedBox(height: 24),
            Row(
              children: [
                FilledButton(
                  onPressed: _recorded == null
                      ? null
                      : () async {
                          final hk = _recorded!;
                          await app.setScreenshotHotkey(
                              HotkeyService.instance.encode(hk));
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(content: Text('已保存：${hk.debugName}')));
                            Navigator.of(context).pop(true);
                          }
                        },
                  child: const Text('保存'),
                ),
                const SizedBox(width: 12),
                OutlinedButton(
                  onPressed: () async {
                    await app.setScreenshotHotkey(null);
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('已恢复默认 Alt+A')));
                      Navigator.of(context).pop(true);
                    }
                  },
                  child: const Text('恢复默认'),
                ),
              ],
            ),
            const SizedBox(height: 16),
            const Text('提示：保存后立即生效；组合键需包含至少一个修饰键（Ctrl/Alt/Shift）。',
                style: TextStyle(color: Colors.black45, fontSize: 12)),
          ],
        ),
      ),
    );
  }
}
