import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:window_manager/window_manager.dart';

import '../services/background_service.dart';
import '../services/firewall_service.dart';
import '../services/hotkey_service.dart';
import '../services/screenshot_service.dart';
import '../state/app_state.dart';
import 'widgets/chat_panel.dart';
import 'widgets/device_sidebar.dart';

/// 主页面：QQ 式布局。宽屏（桌面）左右分栏；窄屏（手机）列表 + 会话页跳转。
class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  late final AppState _app;
  String? _lastHotkeyJson;
  bool _hotkeyInited = false;

  bool get _isDesktop => !Platform.isAndroid && !Platform.isIOS;

  @override
  void initState() {
    super.initState();
    _app = context.read<AppState>();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (_isDesktop) {
        await _registerHotkey();
        _checkFirewall();
      } else if (Platform.isAndroid && _app.settings.backgroundOnline) {
        await BackgroundKeepAlive.instance.start();
      }
    });
    // 快捷键设置变化时重新注册
    _app.addListener(_onStateChanged);
  }

  @override
  void dispose() {
    _app.removeListener(_onStateChanged);
    if (_isDesktop) HotkeyService.instance.unregisterAll();
    super.dispose();
  }

  void _onStateChanged() {
    if (!_isDesktop) return;
    final cur = _app.settings.screenshotHotkey;
    if (_hotkeyInited && cur != _lastHotkeyJson) {
      _registerHotkey();
    }
  }

  Future<void> _registerHotkey() async {
    _hotkeyInited = true;
    _lastHotkeyJson = _app.settings.screenshotHotkey;
    await HotkeyService.instance
        .registerScreenshot(_app.settings.screenshotHotkey, _onScreenshotHotkey);
  }

  static bool _fwChecked = false;

  /// 桌面端检测 Windows 防火墙入站规则，缺失时引导一键放行
  Future<void> _checkFirewall() async {
    if (_fwChecked || !Platform.isWindows) return;
    _fwChecked = true;
    final fw = FirewallService.instance;
    if (await fw.ruleMatches()) return;
    if (!mounted) return;
    final doIt = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('允许其他设备连接'),
        content: const Text(
            '检测到 Windows 防火墙尚未放行 CrossLink，这会导致手机扫码/互传连不上。\n\n'
            '点击"一键放行"后，在系统弹窗中选择"是"即可自动完成，无需手动设置防火墙。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('暂不')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('一键放行')),
        ],
      ),
    );
    if (doIt != true || !mounted) return;

    // 提权期间给出可见反馈（PowerShell 校验 + UAC 可能耗时十几秒）
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => AlertDialog(
        content: Row(
          children: const [
            SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(strokeWidth: 2.5)),
            SizedBox(width: 16),
            Expanded(child: Text('正在请求管理员权限\n请在弹出的系统窗口中选择「是」…')),
          ],
        ),
      ),
    );
    final ok = await fw.ensureRule();
    if (!mounted) return;
    Navigator.of(context).pop(); // 关闭进度
    await showDialog<void>(
      context: context,
      builder: (_) => AlertDialog(
        icon: Icon(ok ? Icons.check_circle_outline : Icons.error_outline,
            color: ok ? Colors.green : Colors.red, size: 36),
        title: Text(ok ? '放行成功' : '放行失败'),
        content: Text(ok
            ? '已添加防火墙入站规则，其他设备现在可以连入本机。'
            : '没能完成放行：可能是 UAC 弹窗点了「否」、当前账户不是管理员，'
                '或被安全软件拦截。可稍后到 设置 → 防火墙一键放行 再试，'
                '或用 设置 → 网络诊断 查看具体原因。'),
        actions: [
          FilledButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('知道了')),
        ],
      ),
    );
  }

  /// 全局快捷键触发：截图并发送到当前会话/所选设备
  Future<void> _onScreenshotHotkey() async {
    try {
      await windowManager.minimize();
      await Future.delayed(const Duration(milliseconds: 250));
    } catch (_) {}
    final bytes = await ScreenshotService.instance.captureRegion();
    try {
      await windowManager.restore();
    } catch (_) {}
    if (bytes != null) {
      await _app.sendImageBytes(bytes,
          name: 'shot_${DateTime.now().millisecondsSinceEpoch}.png');
    }
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, c) {
        final wide = c.maxWidth >= 720;
        if (wide) {
          return const Scaffold(
            // SafeArea：Android 15+ 强制边到边，需避让系统导航条/挖孔
            body: SafeArea(
              child: Row(
                children: [
                  SizedBox(width: 280, child: DeviceSidebar()),
                  VerticalDivider(width: 1),
                  Expanded(child: ChatPanel()),
                ],
              ),
            ),
          );
        }
        // 移动端：设备列表为主页，点选后跳转会话页
        return Scaffold(
          appBar: AppBar(
            title: const Text('CrossLink'),
            backgroundColor: Theme.of(context).colorScheme.primary,
            foregroundColor: Colors.white,
          ),
          body: SafeArea(
            child: DeviceSidebar(
              onOpenPeer: (_) => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const _MobileChatPage()),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// 移动端全屏会话页
class _MobileChatPage extends StatelessWidget {
  const _MobileChatPage();

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final matches = app.peers.where((p) => p.id == app.activePeerId);
    final name = matches.isEmpty ? '会话' : matches.first.name;
    return Scaffold(
      appBar: AppBar(
        title: Text(name),
        backgroundColor: Theme.of(context).colorScheme.primary,
        foregroundColor: Colors.white,
      ),
      body: const SafeArea(child: ChatPanel()),
    );
  }
}
