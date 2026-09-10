import 'dart:async';
import 'dart:io';

import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../services/firewall_service.dart';
import '../services/print_engine.dart';
import '../services/print_share_service.dart';
import '../services/printer_probe.dart';
import '../services/printing/print_service.dart';
import '../state/app_state.dart';
import 'print_jobs_page.dart';

/// 页面角色：主机端（共享我的打印机）/ 同事端（连接别人的打印机）。
/// 打印服务的两类功能面向两种身份，分流后每屏只有一个主操作。
enum _Role { host, client }

/// 主机端「打印服务」设置页（仅 Windows 入口）。
class PrintServicePage extends StatefulWidget {
  const PrintServicePage({super.key});

  @override
  State<PrintServicePage> createState() => _PrintServicePageState();
}

class _PrintServicePageState extends State<PrintServicePage> {
  List<PrinterInfo> _printers = const [];
  PrinterCaps _caps =
      const PrinterCaps(duplex: false, color: false, maxCopies: 1, papers: []);
  PrintState _state = PrintState.offline;
  String _localIp = '';
  Timer? _poll;
  _Role _role = _Role.host;

  /// 首次加载完成前显示"检测中"，避免先闪一下灰色误导
  bool _loaded = false;

  /// 当前能力缓存对应的打印机（切换后重新查询一次）
  String _capsFor = '';

  AppState get _app => context.read<AppState>();

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _poll?.cancel();
    _urlCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final ps = await PrintEngine.instance.listPrinters();
      final ips = await NetworkInterface.list(type: InternetAddressType.IPv4);
      String ip = '';
      for (final ni in ips) {
        for (final a in ni.addresses) {
          if (!a.isLoopback && ip.isEmpty) ip = a.address;
        }
      }
      if (!mounted) return;
      setState(() {
        _printers = ps;
        _localIp = ip;
      });
      _shared = await PrintShareService.isShared();
      _sharedName = await PrintShareService.sharedPrinter();
      // 同步到全局状态：首页打印灯由此驱动
      _app.smbShared = _shared;
      if (mounted) setState(() => _loaded = true);
    } catch (_) {
      if (mounted) setState(() => _loaded = true);
    }
    _startPoll();
  }

  /// 轻量轮询：10 秒一次，仅查状态位 + 网络探测，全程不触碰驱动能力
  /// 查询（DeviceCapabilitiesW），因此不会弹"等待连接"框、不阻塞。
  void _startPoll() {
    _poll?.cancel();
    _poll = Timer.periodic(
        const Duration(seconds: 10), (_) => _refreshStatus(pollCaps: false));
    _refreshStatus(pollCaps: true);
  }

  Future<void> _refreshStatus({bool pollCaps = false}) async {
    final printer = _app.settings.printPrinter;
    // 打印机状态只取决于是否选了打印机，与 IPP 服务开关无关
    if (printer.isEmpty) {
      if (mounted) {
        setState(() {
          _state = PrintState.offline;
          _caps = const PrinterCaps(
              duplex: false, color: false, maxCopies: 1, papers: []);
        });
      }
      return;
    }
    try {
      // 1) spooler 状态位（本地队列视角，网络打印机关机时常误报"就绪"）
      final bits = await PrintEngine.instance.printerStatus(printer)
          .timeout(const Duration(seconds: 5));
      if (!mounted) return;
      var state = PrintEngine.stateOf(bits);

      // 2) 网络端口轻量在线探测（TCP/WS-Discovery），纠正 spooler 误报。
      //    不触发驱动、无弹窗——旧方案靠驱动连设备"顺便"探活，
      //    代价是反复弹等待框，已弃用。
      final port = _printers
          .firstWhereOrNull((p) => p.name == printer)
          ?.port ?? '';
      final online = await PrinterProbe.online(port);
      if (online == false) {
        state = PrintState.offline;
      } else if (online == true && state == PrintState.offline) {
        state = PrintState.ready; // spooler 缓存了过期的离线标记
      }
      if (!mounted) return;
      setState(() => _state = state);

      // 3) 能力查询：只在进页/切换打印机且状态就绪时做（能力不会变）
      if (state == PrintState.ready && (pollCaps || _capsFor != printer)) {
        final caps = await PrintEngine.instance.printerCaps(printer)
            .timeout(const Duration(seconds: 5));
        if (mounted) {
          setState(() {
            _caps = caps;
            _capsFor = printer;
          });
        }
      }
    } catch (_) {
      if (mounted) setState(() => _state = PrintState.offline);
    }
  }

  String get _accessUrl => _app.settings.printToken.isEmpty
      ? '—'
      : 'http://$_localIp:${PrintService.instance.port}/printers/${_app.settings.printToken}';

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('打印服务')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          SegmentedButton<_Role>(
            segments: const [
              ButtonSegment(
                value: _Role.host,
                icon: Icon(Icons.hub_outlined),
                label: Text('共享我的打印机'),
              ),
              ButtonSegment(
                value: _Role.client,
                icon: Icon(Icons.print_outlined),
                label: Text('连接同事的'),
              ),
            ],
            selected: {_role},
            onSelectionChanged: (v) => setState(() => _role = v.first),
          ),
          const SizedBox(height: 12),
          if (_role == _Role.host) ..._hostView(),
          if (_role == _Role.client) _connectCard(),
        ],
      ),
    );
  }

  /// 主机端视图：一张主卡（选打印机+共享状态+连接串）+ 两个功能行 + 折叠的 IPP。
  List<Widget> _hostView() {
    final s = context.watch<AppState>().settings;
    return [
      _hostMainCard(),
      const SizedBox(height: 12),
      Card(
        child: Column(
          children: [
            ListTile(
              leading: const Icon(Icons.tag_outlined),
              title: const Text('每日打印页数配额'),
              subtitle: Text('${s.printDailyPages} 页 / 天'
                  '（今日已用 ${PrintService.instance.todayPagesUsed} 页）'),
              trailing: const Icon(Icons.chevron_right),
              onTap: _editQuota,
            ),
            const Divider(height: 1, indent: 16, endIndent: 16),
            ListTile(
              leading: const Icon(Icons.list_alt_outlined),
              title: const Text('打印任务监控'),
              subtitle: const Text('查看队列、取消任务、暂停/恢复'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => const PrintJobsPage())),
            ),
          ],
        ),
      ),
      _advancedCard(),
    ];
  }

  /// 主机端主卡：Windows 原生共享（SMB）——共享状态、打印机选择、连接串。
  Widget _hostMainCard() {
    final s = context.watch<AppState>().settings;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.hub_outlined,
                    color: Theme.of(context).colorScheme.primary),
                const SizedBox(width: 8),
                Text('Windows 原生共享',
                    style: Theme.of(context).textTheme.titleMedium),
                const Spacer(),
                Chip(
                  label: Text(_shared ? '已共享' : '未共享',
                      style: const TextStyle(fontSize: 11)),
                  backgroundColor:
                      _shared ? Colors.green.shade100 : Colors.grey.shade200,
                  visualDensity: VisualDensity.compact,
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              _shared ? '把下方连接串发给同事，其电脑上任何软件都能直接打印' : '一键把这台电脑上的打印机共享给同事，需一次 UAC 确认',
              style: const TextStyle(fontSize: 12, color: Colors.black54),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              initialValue: s.printPrinter.isEmpty ? null : s.printPrinter,
              decoration: const InputDecoration(
                  labelText: '共享的打印机', border: OutlineInputBorder()),
              items: [
                for (final p in _printers.where((p) => !p.name.contains('OneNote') && !p.name.contains('XPS') && !p.name.contains('PDF') && !p.name.contains('Fax')))
                  DropdownMenuItem(
                      value: p.name,
                      child: Text(p.name, overflow: TextOverflow.ellipsis)),
              ],
              onChanged: (v) async {
                if (v != null) await _app.setPrintPrinter(v);
                _refreshStatus();
              },
            ),
            const SizedBox(height: 10),
            // 选择与实际共享不一致的提示：共享后换选打印机时共享不会自动跟过去
            if (_shared &&
                _sharedName != null &&
                _sharedName != s.printPrinter)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(
                  '注意：当前共享中的是「$_sharedName」，'
                  '与上方选择的「${s.printPrinter}」不同。'
                  '如需改共享所选打印机，点下方「重新生成连接串」。',
                  style: TextStyle(
                      fontSize: 11, color: Colors.orange.shade800),
                ),
              ),
            Row(
              children: [
                if (_loaded) ...[
                  _StateDot(_state),
                  const SizedBox(width: 8),
                  Text(_stateLabel(),
                      style: Theme.of(context).textTheme.bodyMedium),
                  // 打印机能力：仅作提示，实际双面/彩色由打印方
                  // 在自己软件的打印对话框里选择，主机不控制
                  if (_caps.duplex || _caps.color) ...[
                    const SizedBox(width: 8),
                    Text(
                      '支持${[
                        if (_caps.duplex) '双面',
                        if (_caps.color) '彩色',
                      ].join('/')}（打印方在打印对话框里选）',
                      style: const TextStyle(fontSize: 11, color: Colors.black38),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ] else ...[
                  const SizedBox(
                    width: 12,
                    height: 12,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  const SizedBox(width: 8),
                  Text('正在检测打印机状态…',
                      style: Theme.of(context).textTheme.bodyMedium),
                ],
              ],
            ),
            if (_shared && _shareSpec.isNotEmpty) ...[
              // 状态A：本次会话刚启用/重新生成过，连接串在手，直接展示
              const Divider(height: 24),
              const Text('把这行发给同事（CrossLink 里粘贴后一键安装）：',
                  style: TextStyle(fontSize: 11, color: Colors.black45)),
              const SizedBox(height: 4),
              SelectableText(_shareSpec,
                  style:
                      const TextStyle(fontFamily: 'Consolas', fontSize: 12)),
              const SizedBox(height: 4),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton.icon(
                    icon: const Icon(Icons.copy_outlined, size: 18),
                    label: const Text('复制'),
                    onPressed: () {
                      Clipboard.setData(ClipboardData(text: _shareSpec));
                      ScaffoldMessenger.of(context)
                          .showSnackBar(const SnackBar(content: Text('已复制')));
                    },
                  ),
                  TextButton.icon(
                    icon: const Icon(Icons.refresh_outlined, size: 18),
                    label: const Text('重新生成（旧串作废）'),
                    onPressed: _enableShare,
                  ),
                  TextButton.icon(
                    icon: const Icon(Icons.stop_circle_outlined, size: 18),
                    label: const Text('停止共享'),
                    onPressed: _disableShare,
                  ),
                ],
              ),
            ] else if (_shared) ...[
              // 状态B：已共享但本会话没有连接串（如重新打开页面）。
              // 此时共享已在生效，同事可正常打印；密码不在本地保存，
              // 想邀请新同事只能重新生成。绝不能在这里放显眼的"启用共享"
              // 引导按钮——新手会误点，导致旧连接串全部失效。
              const Divider(height: 24),
              Text('共享已在生效，已连接的同事可正常打印。\n'
                  '连接串密码不在本机保存；要邀请新同事，点下方重新生成一份'
                  '（旧连接串将失效，已连接的同事不受影响）。',
                  style: const TextStyle(fontSize: 12, color: Colors.black54)),
              const SizedBox(height: 4),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton.icon(
                    icon: const Icon(Icons.refresh_outlined, size: 18),
                    label: const Text('重新生成连接串'),
                    onPressed: _enableShare,
                  ),
                  TextButton.icon(
                    icon: const Icon(Icons.stop_circle_outlined, size: 18),
                    label: const Text('停止共享'),
                    onPressed: _disableShare,
                  ),
                ],
              ),
            ] else
              // 状态C：未共享——唯一出现醒目主按钮的场景
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Align(
                  alignment: Alignment.centerRight,
                  child: FilledButton.icon(
                    icon: const Icon(Icons.share_outlined, size: 18),
                    label: const Text('启用共享'),
                    onPressed: _enableShare,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// 高级（折叠）：IPP 服务——手机/未来设备走的标准协议，桌面同事端用 SMB 即可。
  Widget _advancedCard() {
    final s = context.watch<AppState>().settings;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Theme(
        // 去掉 ExpansionTile 内边距，让内容对齐卡片
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          tilePadding: const EdgeInsets.symmetric(horizontal: 16),
          childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          title: const Text('高级：IPP 打印服务（手机/其他设备）',
              style: TextStyle(fontSize: 14)),
          subtitle: Text(
              s.printEnabled ? '已开启，监听端口 ${PrintService.instance.port}' : '默认关闭',
              style: const TextStyle(fontSize: 11, color: Colors.black45)),
          children: [
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              secondary: const Icon(Icons.print_outlined),
              title: const Text('开启 IPP 服务'),
              subtitle: Text(s.printEnabled
                  ? '手机等 IPP 设备可通过下方地址向这台打印机出纸'
                  : '开启后手机等 IPP 设备可经局域网向这台打印机出纸'),
              value: s.printEnabled,
              onChanged: _onToggle,
            ),
            if (s.printEnabled) ...[
              const SizedBox(height: 8),
              Text('同事/手机的接入地址',
                  style: Theme.of(context).textTheme.titleSmall),
              const SizedBox(height: 8),
              SelectableText(
                _accessUrl,
                style: const TextStyle(fontFamily: 'Consolas'),
              ),
              const SizedBox(height: 4),
              Text(
                '控制面板 → 设备和打印机 → 添加打印机 → 选择“我所需打印机不在列表中”'
                ' → “通过 TCP/IP 地址或主机名添加”，或直接粘贴上述地址（Windows 10/11 自带 IPP 驱动）。',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton.icon(
                    icon: const Icon(Icons.copy_outlined, size: 18),
                    label: const Text('复制地址'),
                    onPressed: () {
                      Clipboard.setData(ClipboardData(text: _accessUrl));
                      ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('已复制')));
                    },
                  ),
                  TextButton.icon(
                    icon: const Icon(Icons.refresh_outlined, size: 18),
                    label: const Text('重置令牌'),
                    onPressed: _resetToken,
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  bool _shared = false;
  String _shareSpec = '';

  /// 实际挂 CrossLinkPrint 共享名的打印机（可能与所选打印机不一致）
  String? _sharedName;

  Future<void> _enableShare() async {
    final printer = _app.settings.printPrinter;
    if (printer.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('请先选择要共享的打印机')));
      return;
    }
    final pass = PrintShareService.newSharePassword();
    final yes = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('启用 Windows 原生打印共享'),
        content: Text(
          '将自动完成（需一次 UAC 确认）：\n'
          '1. 创建专用账户 ${PrintShareService.accountName}（仅网络打印用，禁止登录桌面）\n'
          '2. 共享打印机「$printer」为 ${PrintShareService.shareName}\n'
          '3. 开启"文件和打印机共享"防火墙\n\n'
          '本次连接密码：$pass\n（同事连接时需要，可随时重新生成）',
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('启用')),
        ],
      ),
    );
    if (yes != true || !mounted) return;
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const AlertDialog(
        content: Row(children: [
          SizedBox(
              width: 22, height: 22,
              child: CircularProgressIndicator(strokeWidth: 2.5)),
          SizedBox(width: 16),
          Expanded(child: Text('正在配置共享，请在 UAC 弹窗中选「是」…')),
        ]),
      ),
    );
    final (ok, text) = await PrintShareService.enableShare(printer, pass);
    if (!mounted) return;
    Navigator.of(context).pop();
    _app.smbShared = ok; // 首页打印灯随动
    setState(() {
      _shared = ok;
      _sharedName = ok ? printer : null;
      _shareSpec = ok ? PrintShareService.buildSpec(_localIp, pass) : '';
    });
    if (!ok) {
      await showDialog<void>(
        context: context,
        builder: (_) => AlertDialog(
          title: const Text('共享配置未完成'),
          content: SingleChildScrollView(child: Text(text)),
          actions: [
            FilledButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('知道了')),
          ],
        ),
      );
    }
  }

  /// 停止共享：取消打印机共享（需一次 UAC）。
  /// 停的是"实际挂着 CrossLinkPrint 共享名的打印机"，
  /// 与当前下拉选择无关——防止选错对象停了个寂寞。
  /// 专用账户与防火墙放行保留，下次启用仍是"一键"。
  Future<void> _disableShare() async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('停止共享？'),
        content: Text(_sharedName == null
            ? '停止后同事将无法通过这台电脑打印（需一次 UAC 确认）。\n'
              '打印机和所有配置都保留，随时可重新一键启用。'
            : '将停止「$_sharedName」的共享，之后同事将无法通过这台电脑打印'
              '（需一次 UAC 确认）。\n打印机和所有配置都保留，随时可重新一键启用。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('停止')),
        ],
      ),
    );
    if (yes != true || !mounted) return;
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const AlertDialog(
        content: Row(children: [
          SizedBox(
              width: 22, height: 22,
              child: CircularProgressIndicator(strokeWidth: 2.5)),
          SizedBox(width: 16),
          Expanded(child: Text('正在停止共享，请在 UAC 弹窗中选「是」…')),
        ]),
      ),
    );
    final (ok, text) = await PrintShareService.disableShare();
    if (!mounted) return;
    Navigator.of(context).pop();
    _app.smbShared = false; // 首页打印灯随动
    setState(() {
      _shared = false;
      _sharedName = null;
      _shareSpec = '';
    });
    if (!ok) {
      await showDialog<void>(
        context: context,
        builder: (_) => AlertDialog(
          title: const Text('停止共享未完成'),
          content: SingleChildScrollView(child: Text(text)),
          actions: [
            FilledButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('知道了')),
          ],
        ),
      );
    }
  }

  String _stateLabel() => switch (_state) {
        PrintState.ready => '打印机就绪',
        PrintState.problem => '打印机异常（缺纸/卡纸/故障）',
        PrintState.offline => '打印机离线或未连接',
      };

  final _urlCtrl = TextEditingController();

  /// 同事端视图：粘贴连接串，一键添加为系统打印机。
  Widget _connectCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.print_outlined,
                    color: Theme.of(context).colorScheme.primary),
                const SizedBox(width: 8),
                Text('连接共享打印机',
                    style: Theme.of(context).textTheme.titleMedium),
              ],
            ),
            const SizedBox(height: 6),
            const Text('粘贴对方发给你的连接串，点「一键安装」添加为系统打印机，'
                '之后任何软件都能直接打印。',
                style: TextStyle(fontSize: 12, color: Colors.black54)),
            const SizedBox(height: 12),
            TextField(
              controller: _urlCtrl,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                hintText: r'\\IP\共享名 账户 密码',
              ),
            ),
            const SizedBox(height: 10),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton.icon(
                icon: const Icon(Icons.download_outlined, size: 18),
                label: const Text('一键安装'),
                onPressed: _installPrinter,
              ),
            ),
            const SizedBox(height: 6),
            const Text('也支持 IPP 地址（http://IP:631/printers/令牌）。\n'
                '若弹出"输入 Windows 凭据"：用户名随意填，密码填对方给的接入令牌。',
                style: TextStyle(fontSize: 11, color: Colors.black45)),
          ],
        ),
      ),
    );
  }

  static final _urlRe = RegExp(r'^http://[A-Za-z0-9.\-_:]+(:\d+)?(/[A-Za-z0-9\-_./]*)*$');

  Future<void> _installPrinter() async {
    final url = _urlCtrl.text.trim();
    final msg = ScaffoldMessenger.of(context);
    if (url.startsWith('\\\\')) {
      final (ok, err) = await PrintShareService.installFromSpec(url);
      if (!mounted) return;
      msg.showSnackBar(SnackBar(
          content: Text(ok
              ? '已添加！到 控制面板→设备和打印机 可确认'
              : '添加失败：$err')));
      return;
    }
    if (!_urlRe.hasMatch(url)) {
      msg.showSnackBar(const SnackBar(
          content: Text('地址格式不正确（示例 http://192.168.1.8:631/printers/令牌 或 \\\\IP\\共享名 账户 密码）')));
      return;
    }
    try {
      final r = await Process.run('powershell', [
        '-NoProfile',
        '-Command',
        "(New-Object -ComObject WScript.Network).AddPrinterConnection('', '$url')"
      ]);
      if (!mounted) return;
      if (r.exitCode == 0) {
        msg.showSnackBar(const SnackBar(content: Text('已添加！到 控制面板→设备和打印机 可确认')));
      } else {
        msg.showSnackBar(SnackBar(
            content: Text('添加失败：${(r.stderr as String?)?.trim() ?? '未知错误'}\n可改用系统"添加打印机"向导手动接入')));
      }
    } catch (e) {
      if (mounted) {
        msg.showSnackBar(SnackBar(content: Text('添加失败：$e')));
      }
    }
  }

  Future<void> _onToggle(bool v) async {
    if (v && _app.settings.printPrinter.isEmpty) {
      final ok = _printers.isNotEmpty;
      if (ok) {
        final def = _printers.where((p) => p.isDefault).firstOrNull;
        await _app.setPrintPrinter(
            def?.name ?? _printers.first.name);
      }
      if (!mounted) return;
      if (!ok) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('未找到可用打印机')));
        return;
      }
    }
    await _app.setPrintEnabled(v);
    if (v && mounted) {
      // 联动开机自启（无人值守前提）
      if (!_app.settings.autoStart) {
        await _app.setAutoStart(true);
      }
      // 老规则缺打印端口 → 引导补一次放行
      if (!await FirewallService.instance.printRuleOk()) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('首次开启需为打印端口补一条防火墙放行，将弹出一次授权确认')));
        await FirewallService.instance.ensureRule(forceAdd: true);
      }
    }
  }

  Future<void> _resetToken() async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('重置接入令牌？'),
        content: const Text('旧地址立即失效，同事需要改用新地址。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('重置')),
        ],
      ),
    );
    if (yes == true) {
      await _app.setPrintToken(PrintService.instance.newToken());
    }
  }

  Future<void> _editQuota() async {
    final ctrl =
        TextEditingController(text: '${_app.settings.printDailyPages}');
    final v = await showDialog<int>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('每日打印页数配额'),
        content: TextField(
          controller: ctrl,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(
              suffixText: '页 / 天', border: OutlineInputBorder()),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('取消')),
          FilledButton(
              onPressed: () =>
                  Navigator.pop(context, int.tryParse(ctrl.text.trim())),
              child: const Text('保存')),
        ],
      ),
    );
    if (v != null && v > 0) await _app.setPrintDailyPages(v);
  }
}

class _StateDot extends StatelessWidget {
  final PrintState state;
  const _StateDot(this.state);

  @override
  Widget build(BuildContext context) {
    final color = switch (state) {
      PrintState.ready => Colors.green,
      PrintState.problem => Colors.orange,
      PrintState.offline => Colors.grey,
    };
    return Container(
      width: 10,
      height: 10,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
    );
  }
}
