import 'dart:ffi' hide Size;
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter/material.dart';
import 'package:hotkey_manager/hotkey_manager.dart';
import 'package:provider/provider.dart';
import 'package:window_manager/window_manager.dart';

import 'core/logger.dart';
import 'services/firewall_service.dart';
import 'services/taskbar_flash.dart';
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
  // 硬终止原语：TerminateProcess 不执行析构与 DLL 卸载，物理上无法卡死。
  // 关键修复：此前第二实例用 exit(0) 退出，会在引擎启动早期触发 DLL
  // 卸载死锁，进程变成无法结束的僵尸（taskkill/Stop-Process 均无效），
  // 且僵尸持有本互斥锁不放，导致此后所有启动全部连锁变僵尸。
  final getCurrentProcess = kernel32.lookupFunction<
      IntPtr Function(),
      int Function()>('GetCurrentProcess');
  final terminateProcess = kernel32.lookupFunction<
      Int32 Function(IntPtr, Uint32),
      int Function(int, int)>('TerminateProcess');

  const swRestore = 9;
  const errorAlreadyExists = 183;

  final mutexName = 'CrossLink_SingleInstance_Mutex'.toNativeUtf16();
  createMutex(0, 0, mutexName);

  if (getLastError() == errorAlreadyExists) {
    // 尝试找到已有窗口并提到前台：先按标题找（标题由 Dart 侧设置），
    // 找不到再按窗口类找（实例尚在启动早期或已挂起时标题未设置）
    final windowTitle = 'CrossLink 跨端互传'.toNativeUtf16();
    final windowClass = 'FLUTTER_RUNNER_WIN32_WINDOW'.toNativeUtf16();
    final nullPtr = Pointer<Utf16>.fromAddress(0);
    var hwnd = findWindow(nullPtr, windowTitle);
    if (hwnd == 0) hwnd = findWindow(windowClass, nullPtr);
    if (hwnd != 0) {
      showWindow(hwnd, swRestore);
      setForegroundWindow(hwnd);
    }
    terminateProcess(getCurrentProcess(), 0);
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

class _CrossLinkAppState extends State<CrossLinkApp>
    with WindowListener, WidgetsBindingObserver {
  static final _isDesktop =
      Platform.isWindows || Platform.isLinux || Platform.isMacOS;
  final _navKey = GlobalKey<NavigatorState>();
  bool _handlingClose = false;

  AppState get _app => widget.state;

  @override
  void initState() {
    super.initState();
    // 观察者在桌面/移动两端都要注册（安卓有前台服务保活，
    // 退到后台照样收消息，必须知道"此刻用户看不看得见"）
    WidgetsBinding.instance.addObserver(this);
    if (!_isDesktop) return;
    windowManager.addListener(this);
    TrayService.instance
      ..onExitRequested = _quitApp
      ..init();
    _app.addListener(_syncPreventClose);
    _app.addListener(_syncUnreadAttention);
    _syncPreventClose();
    // windowManager.getId() 在 Windows 上返回的就是主窗口 HWND，
    // 取一次缓存起来，之后任务栏闪烁/停止都用它
    windowManager.getId().then((v) => _hwnd = v).catchError((_) => 0);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    if (_isDesktop) {
      _app.removeListener(_syncPreventClose);
      _app.removeListener(_syncUnreadAttention);
      windowManager.removeListener(this);
    }
    super.dispose();
  }

  /// 前后台切换 → 维护可见性。
  ///
  /// inactive（被其它窗口夺焦但仍看得见）算可见：此时用户确实能看到
  /// 新消息，不该攒未读。hidden（最小化/切后台/收进托盘）才算不可见。
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _app.windowVisible = state == AppLifecycleState.resumed ||
        state == AppLifecycleState.inactive;
  }

  /// 主窗口 HWND（0 = 尚未取到）
  int _hwnd = 0;

  /// 上一次观察到的未读总数，用来识别"新增未读"这条沿
  int _lastUnread = 0;

  /// 未读变化 → 任务栏闪烁。
  ///
  /// 只在"新增未读"这条沿上触发，避免每次 notifyListeners 都重闪一次；
  /// 窗口就在前台时不闪——用户正看着，闪了只是噪音。
  void _syncUnreadAttention() {
    if (!_isDesktop) return;
    final n = _app.totalUnread;
    if (n == 0) {
      if (_lastUnread != 0 && _hwnd != 0) TaskbarFlash.stop(_hwnd);
      _lastUnread = 0;
      return;
    }
    if (n > _lastUnread) {
      _attentionNeeded();
    } else {
      _lastUnread = n;
    }
  }

  Future<void> _attentionNeeded() async {
    _lastUnread = _app.totalUnread;
    if (_hwnd == 0) return;
    final visible = await windowManager.isVisible();
    final focused = await windowManager.isFocused();
    if (visible && focused) {
      TaskbarFlash.stop(_hwnd);
      return;
    }
    TaskbarFlash.start(_hwnd);
  }

  /// 收入托盘：隐藏窗口的同时把可见性置 false。
  /// 漏了这一步，新消息会被判定为"用户看得见"而直接算已读，
  /// 未读数永远不增长，任务栏闪烁也就永远不会触发。
  Future<void> _hideToTray() async {
    await windowManager.hide();
    _app.windowVisible = false;
  }

  @override
  void onWindowFocus() {
    _app.windowVisible = true;
    if (_hwnd != 0) TaskbarFlash.stop(_hwnd);
    _app.syncActiveRead(); // 回到前台：正看着的会话视为已读
  }

  @override
  void onWindowRestore() {
    _app.windowVisible = true;
    _app.syncActiveRead();
  }

  @override
  void onWindowMinimize() => _app.windowVisible = false;

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
          await _hideToTray();
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
      await _hideToTray();
      return;
    }
    final result = await showDialog<_CloseChoice>(
      context: ctx,
      builder: (_) => const _CloseChoiceDialog(),
    );
    if (result == null) return; // 取消，窗口保持打开
    if (result.remember) await _app.setCloseBehavior(result.action);
    if (result.action == 'tray') {
      await _hideToTray();
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
          // 注意：不要在这里包全局 SafeArea——那会让背景色也避开状态栏
          // 和导航条，App 被缩成"长方形"（实测踩坑）。正确做法：背景全屏
          // 铺满（edge-to-edge），每个页面的【内容区】自己包 SafeArea。
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
