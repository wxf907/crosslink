import 'dart:async';
import 'dart:io';

import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../services/firewall_service.dart';
import '../services/print_engine.dart';
import '../services/print_share_service.dart';
import '../services/printing/print_service.dart';
import '../state/app_state.dart';
import 'print_jobs_page.dart';

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
      if (mounted) setState(() {});
    } catch (_) {}
    _startPoll();
  }

  void _startPoll() {
    _poll?.cancel();
    _poll = Timer.periodic(const Duration(seconds: 3), (_) => _refreshStatus());
    _refreshStatus();
  }

  Future<void> _refreshStatus() async {
    final printer = _app.settings.printPrinter;
    if (printer.isEmpty || !_app.settings.printEnabled) {
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
      final bits = await PrintEngine.instance.printerStatus(printer);
      final caps = await PrintEngine.instance.printerCaps(printer);
      if (!mounted) return;
      setState(() {
        _state = PrintEngine.stateOf(bits);
        _caps = caps;
      });
    } catch (_) {}
  }

  String get _accessUrl => _app.settings.printToken.isEmpty
      ? '—'
      : 'http://$_localIp:${PrintService.instance.port}/printers/${_app.settings.printToken}';

  @override
  Widget build(BuildContext context) {
    final s = context.watch<AppState>().settings;
    return Scaffold(
      appBar: AppBar(title: const Text('打印服务')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (Platform.isWindows) _smbShareCard(),
          if (Platform.isWindows) const SizedBox(height: 12),
          Card(
            child: SwitchListTile(
              secondary: const Icon(Icons.print_outlined),
              title: const Text('共享本机打印机（IPP，供手机/未来设备）'),
              subtitle: Text(s.printEnabled
                  ? 'IPP 服务运行中：同事在系统中添加下方网络打印机地址即可直接打印'
                  : '开启后手机等 IPP 设备可经局域网向这台打印机出纸'),
              value: s.printEnabled,
              onChanged: _onToggle,
            ),
          ),
          const SizedBox(height: 12),
          Card(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Column(
                children: [
                  DropdownButtonFormField<String>(
                    initialValue: s.printPrinter.isEmpty ? null : s.printPrinter,
                    decoration: const InputDecoration(labelText: '共享的打印机'),
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
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      _StateDot(_state),
                      const SizedBox(width: 8),
                      Text(_stateLabel(), style: Theme.of(context).textTheme.bodyMedium),
                      const Spacer(),
                    ],
                  ),
                  if (s.printEnabled)
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Wrap(
                        spacing: 6,
                        runSpacing: 6,
                        children: [
                          if (_caps.duplex) const _Chip('自动双面'),
                          if (_caps.color) const _Chip('彩色'),
                          if (_caps.papers.isEmpty)
                            const _Chip('默认 A4')
                          else
                            _Chip('纸张 ${_caps.papers.length} 种'),
                          _Chip('单次最多 ${_caps.maxCopies.clamp(0, 99)} 份'),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          if (s.printEnabled) ...[
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('同事的接入地址',
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
                ),
              ),
            ),
            const SizedBox(height: 12),
          ],
          ListTile(
            leading: const Icon(Icons.tag_outlined),
            title: const Text('每日打印页数配额'),
            subtitle: Text('${s.printDailyPages} 页 / 天'
                '（今日已用 ${PrintService.instance.todayPagesUsed} 页）'),
            trailing: const Icon(Icons.chevron_right),
            onTap: _editQuota,
          ),
          ListTile(
            leading: const Icon(Icons.list_alt_outlined),
            title: const Text('打印任务监控'),
            subtitle: const Text('查看队列、取消任务、暂停/恢复'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => const PrintJobsPage())),
          ),
          const SizedBox(height: 8),
          _connectCard(),
        ],
      ),
    );
  }

  bool _shared = false;
  String _shareSpec = '';

  Widget _smbShareCard() {
    return Card(
      color: Theme.of(context).colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
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
                Text('Windows 原生共享（推荐同事电脑用）',
                    style: Theme.of(context).textTheme.titleSmall),
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
            const SizedBox(height: 6),
            const Text(
              '走 Windows 自带打印共享：同事电脑只需"名称+密码"即可连接，'
              '最稳定。启用时会弹一次 UAC，自动创建专用打印账户并共享打印机。',
              style: TextStyle(fontSize: 12, color: Colors.black54),
            ),
            if (_shared && _shareSpec.isNotEmpty) ...[
              const SizedBox(height: 8),
              SelectableText(_shareSpec,
                  style: const TextStyle(fontFamily: 'Consolas', fontSize: 12)),
              const Text('把上面这行发给同事，他在 CrossLink 打印服务页粘贴后点一键安装。',
                  style: TextStyle(fontSize: 11, color: Colors.black45)),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton.icon(
                  icon: const Icon(Icons.copy_outlined, size: 18),
                  label: const Text('复制连接串'),
                  onPressed: () {
                    Clipboard.setData(ClipboardData(text: _shareSpec));
                    ScaffoldMessenger.of(context)
                        .showSnackBar(const SnackBar(content: Text('已复制')));
                  },
                ),
              ),
            ],
            const SizedBox(height: 4),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton.icon(
                icon: const Icon(Icons.share_outlined, size: 18),
                label: Text(_shared ? '重新生成连接串' : '启用原生共享'),
                onPressed: _enableShare,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _enableShare() async {
    final printer = _app.settings.printPrinter;
    if (printer.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('请先在下方选择要共享的打印机')));
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
    setState(() {
      _shared = ok;
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

  String _stateLabel() => switch (_state) {
        PrintState.ready => '打印机就绪',
        PrintState.problem => '打印机异常（缺纸/离线/故障）',
        PrintState.offline => '未共享或打印机离线',
      };

  final _urlCtrl = TextEditingController();

  /// 未开启共享时显示：粘贴同事给的接入地址，一键添加为系统打印机
  Widget _connectCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('连接到同事共享的打印机',
                style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 6),
            const Text('粘贴对方发给你的连接串（\\\\IP\\共享名 账户 密码）或 IPP 地址'
                '（http://IP:631/printers/令牌），点「一键安装」添加为系统打印机；'
                '之后任何软件都能直接打印。',
                style: TextStyle(fontSize: 12, color: Colors.black54)),
            const SizedBox(height: 10),
            TextField(
              controller: _urlCtrl,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                hintText: 'http://…/printers/…',
              ),
            ),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton.icon(
                icon: const Icon(Icons.print_outlined, size: 18),
                label: const Text('一键安装'),
                onPressed: _installPrinter,
              ),
            ),
            const SizedBox(height: 6),
            const Text('若弹出"输入 Windows 凭据"：用户名随意填，密码填对方给的接入令牌。',
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

class _Chip extends StatelessWidget {
  final String label;
  const _Chip(this.label);

  @override
  Widget build(BuildContext context) => Chip(
        label: Text(label, style: const TextStyle(fontSize: 12)),
        visualDensity: VisualDensity.compact,
        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      );
}
