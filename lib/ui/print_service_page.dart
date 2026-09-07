import 'dart:async';
import 'dart:io';

import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../core/constants.dart';
import '../services/firewall_service.dart';
import '../services/print_engine.dart';
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
      : 'http://$_localIp:${AppConst.printPort}/printers/${_app.settings.printToken}';

  @override
  Widget build(BuildContext context) {
    final s = context.watch<AppState>().settings;
    return Scaffold(
      appBar: AppBar(title: const Text('打印服务')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: SwitchListTile(
              secondary: const Icon(Icons.print_outlined),
              title: const Text('共享本机打印机（IPP）'),
              subtitle: Text(s.printEnabled
                  ? '同事在系统中添加下方网络打印机地址即可直接打印，无需本机密码'
                  : '开启后同事可通过系统自带打印界面，经局域网向这台打印机出纸'),
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
        ],
      ),
    );
  }

  String _stateLabel() => switch (_state) {
        PrintState.ready => '打印机就绪',
        PrintState.problem => '打印机异常（缺纸/离线/故障）',
        PrintState.offline => '未共享或打印机离线',
      };

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
