import 'dart:ffi' hide Size;
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter/material.dart';
import 'package:hotkey_manager/hotkey_manager.dart';
import 'package:provider/provider.dart';
import 'package:window_manager/window_manager.dart';

import 'core/logger.dart';
import 'services/firewall_service.dart';
import 'services/tray_service.dart';
import 'state/app_state.dart';
import 'ui/home_page.dart';
import 'ui/login_page.dart';

/// Windows 单实例检测：通过命名互斥锁判断是否已有实例运行。
/// 如果已有实例，将已有窗口提到前台后退出新进程。
void _ensureSingleInstance() {
  if (!Platform.isWindows) return;

  final kernel32 = DynamicLibrary.open('kernel32.dll');
  final user32 = DynamicLibrary.open('user32.dll');

  final createMutex = kernel32.lookupFunction<
      IntPtr Function(IntPtr, Int32, Pointer<Utf16>),
      int Function(int, int, Pointer<Utf16>)>('CreateMutexW');
  final getLastError = kernel32.lookupFunction<
      Uint32 Function(),
      int Function()>('GetLastError');
  final findWindow = user32.lookupFunction<
      IntPtr Function(Pointer<Utf16>, Pointer<Utf16>),
      int Function(Pointer<Utf16>, Pointer<Utf16>)>('FindWindowW');
  final setForegroundWindow = user32.lookupFunction<
      Int32 Function(IntPtr),
      int Function(int)>('SetForegroundWindow');
  final showWindow = user32.lookupFunction<
      Int32 Function(IntPtr, Int32),
      int Function(int, int)>('ShowWindow');

  const swRestore = 9;
  const errorAlreadyExists = 183;

  final mutexName = 'CrossLink_SingleInstance_Mutex'.toNativeUtf16();
  createMutex(0, 0, mutexName);

  if (getLastError() == errorAlreadyExists) {
    // 尝试找到已有窗口并提到前台
    final windowTitle = 'CrossLink 跨端互传'.toNativeUtf16();
    final hwnd =
        findWindow(Pointer<Utf16>.fromAddress(0), windowTitle);
    if (hwnd != 0) {
      showWindow(hwnd, swRestore);
      setForegroundWindow(hwnd);
    }
    exit(0);
  }
}

/// 全局 SnackBar 入口
final GlobalKey<ScaffoldMessengerState> messengerKey =
    GlobalKey<ScaffoldMessengerState>();

Future<void> main(List<String> args) async {
  // 提权实例：只添加防火墙规则后立即退出，不启动界面
  if (args.contains(FirewallService.addRuleFlag)) {
    await FirewallService.instance.addRuleDirectly();
    exit(0);
  }

  // Windows 单实例检测：已有实例则提到前台并退出
  _ensureSingleInstance();

  WidgetsFlutterBinding.ensureInitialized();

  // 桌面端窗口与全局快捷键初始化
  if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
    await windowManager.ensureInitialized();
    // 清理遗留的全局快捷键注册
    await hotKeyManager.unregisterAll();
    const opts = WindowOptions(
      size: Size(1040, 680),
      minimumSize: Size(820, 540),
      center: true,
      title: 'CrossLink 跨端互传',
      titleBarStyle: TitleBarStyle.normal,
    );
    await windowManager.waitUntilReadyToShow(opts, () async {
      await windowManager.show();
      await windowManager.focus();
    });
  }

  final state = AppState();
  await state.init();

  runApp(CrossLinkApp(state: state));
}

class CrossLinkApp extends StatefulWidget {
  final AppState state;
  const CrossLinkApp({super.key, required this.state});

  @override
  State<CrossLinkApp> createState() => _CrossLinkAppState();
}

class _CrossLinkAppState extends State<CrossLinkApp> with WindowListener {
  static final _isDesktop =
      Platform.isWindows || Platform.isLinux || Platform.isMacOS;
  final _navKey = GlobalKey<NavigatorState>();
  bool _handlingClose = false;

  AppState get _app => widget.state;

  @override
  void initState() {
    super.initState();
    if (!_isDesktop) return;
    windowManager.addListener(this);
    TrayService.instance
      ..onExitRequested = _quitApp
      ..init();
    _app.addListener(_syncPreventClose);
    _syncPreventClose();
  }

  @override
  void dispose() {
    if (_isDesktop) {
      _app.removeListener(_syncPreventClose);
      windowManager.removeListener(this);
    }
    super.dispose();
  }

  /// 'quit' 策略下不拦截关闭，让系统直接销毁窗口；其余策略拦截并自行处理
  void _syncPreventClose() {
    windowManager.setPreventClose(_app.settings.closeBehavior != 'quit');
  }

  @override
  void onWindowClose() async {
    if (_handlingClose) return;
    _handlingClose = true;
    try {
      switch (_app.settings.closeBehavior) {
        case 'tray':
          await windowManager.hide();
        case 'quit':
          await _quitApp();
        default:
          await _askClose();
      }
    } finally {
      _handlingClose = false;
    }
  }

  Future<void> _askClose() async {
    final ctx = _navKey.currentContext;
    if (ctx == null) {
      await windowManager.hide();
      return;
    }
    final result = await showDialog<_CloseChoice>(
      context: ctx,
      builder: (_) => const _CloseChoiceDialog(),
    );
    if (result == null) return; // 取消，窗口保持打开
    if (result.remember) await _app.setCloseBehavior(result.action);
    if (result.action == 'tray') {
      await windowManager.hide();
    } else {
      await _quitApp();
    }
  }

  Future<void> _quitApp() async {
    await TrayService.instance.disposeTray();
    await windowManager.destroy();
    exit(0);
  }

  @override
  Widget build(BuildContext context) {
    // 接收侧提示 -> SnackBar
    _app.onNotice = (msg) {
      messengerKey.currentState
        ?..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(msg)));
    };

    return MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: _app),
        ChangeNotifierProvider.value(value: LogService.instance),
      ],
      child: ListenableBuilder(
        listenable: _app,
        builder: (context, _) => MaterialApp(
          title: 'CrossLink',
          debugShowCheckedModeBanner: false,
          navigatorKey: _navKey,
          scaffoldMessengerKey: messengerKey,
          theme: ThemeData(
            useMaterial3: true,
            colorSchemeSeed: Color(_app.settings.themeColor ?? 0xFF12B7F5),
            scaffoldBackgroundColor: const Color(0xFFF5F6F8),
            fontFamily: Platform.isWindows ? 'Microsoft YaHei' : null,
          ),
          home: Consumer<AppState>(
            builder: (_, s, _) =>
                s.loggedIn ? const HomePage() : const LoginPage(),
          ),
          // 全局避让系统内边距：Android 15+ / iOS 刘海与底部手势条
          // 统一在此处理，所有页面与弹窗自动生效（SafeArea 会消费掉
          // 内边距，页面内再写的 SafeArea 不会叠加重复留白）
          builder: (context, child) => SafeArea(
            bottom: true,
            top: true,
            left: true,
            right: true,
            minimum: const EdgeInsets.only(bottom: 4),
            child: child ?? const SizedBox.shrink(),
          ),
        ),
      ),
    );
  }
}

class _CloseChoice {
  final String action; // 'tray' | 'quit'
  final bool remember;
  const _CloseChoice(this.action, this.remember);
}

class _CloseChoiceDialog extends StatefulWidget {
  const _CloseChoiceDialog();

  @override
  State<_CloseChoiceDialog> createState() => _CloseChoiceDialogState();
}

class _CloseChoiceDialogState extends State<_CloseChoiceDialog> {
  bool _remember = false;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      icon: const Icon(Icons.close_rounded),
      title: const Text('关闭 CrossLink'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
              '最小化后程序继续在托盘运行，其他设备仍可随时连入；\n'
              '彻底退出则局域网互传一并停止。'),
          CheckboxListTile(
            value: _remember,
            onChanged: (v) => setState(() => _remember = v ?? false),
            title: const Text('记住我的选择（可在 设置 → 其他 修改）'),
            controlAffinity: ListTileControlAffinity.leading,
            contentPadding: EdgeInsets.zero,
            dense: true,
          ),
        ],
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消')),
        TextButton(
            onPressed: () =>
                Navigator.pop(context, const _CloseChoice('quit', false)),
            child: const Text('直接退出')),
        FilledButton(
            onPressed: () => Navigator.pop(
                context, _CloseChoice('tray', _remember)),
            child: const Text('最小化到托盘')),
      ],
    );
  }
}
