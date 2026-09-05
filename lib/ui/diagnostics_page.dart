import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../net/lan_transport.dart';
import '../services/firewall_service.dart';
import '../state/app_state.dart';
import 'widgets/manual_connect.dart';

/// 网络诊断页：把"看不看得见对方、连不连得通对方"两件事拆开呈现，
/// 便于区分「不在同一网段 / 路由器隔离」与「对方防火墙未放行」。
class DiagnosticsPage extends StatefulWidget {
  const DiagnosticsPage({super.key});

  @override
  State<DiagnosticsPage> createState() => _DiagnosticsPageState();
}

class _DiagnosticsPageState extends State<DiagnosticsPage> {
  List<String> _nets = const [];
  int _nicCount = 0;
  bool? _fwAllowed;
  List<PeerDiag> _peers = const [];
  final Map<String, String?> _probeResults = {};
  final Set<String> _probing = {};
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _refresh();
    _timer = Timer.periodic(const Duration(seconds: 2), (_) => _refresh());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _refresh() async {
    if (!mounted) return;
    final app = context.read<AppState>();
    final nets = await app.localNetInfo();
    if (!mounted) return;
    setState(() {
      _nets = nets;
      _nicCount = app.broadcastNicCount;
      _peers = app.peerDiags();
    });
  }

  Future<void> _checkFirewall() async {
    setState(() => _fwAllowed = null);
    final ok = await FirewallService.instance.ruleMatches();
    if (!mounted) return;
    setState(() => _fwAllowed = ok);
  }

  Future<void> _probe(PeerDiag p) async {
    setState(() {
      _probing.add(p.deviceId);
      _probeResults.remove(p.deviceId);
    });
    final r = await context.read<AppState>().probePeer(p.deviceId);
    if (!mounted) return;
    setState(() {
      _probing.remove(p.deviceId);
      _probeResults[p.deviceId] = r;
    });
  }

  String _ago(int ms) {
    if (ms < 1000) return '刚刚';
    final s = ms / 1000;
    if (s < 60) return '${s.toStringAsFixed(0)} 秒前';
    return '${(s / 60).toStringAsFixed(0)} 分钟前';
  }

  String _verdict(PeerDiag p) {
    if (p.connAlive) return '长连接正常';
    if (p.sinceAnnounceMs > 10000) {
      return '收不到对方广播：多半不在同一网段，或路由器开了 AP/客户端隔离';
    }
    if (p.connectFailures >= 2) {
      return '能收到广播但连不上：对方防火墙未放行入站（在对方电脑点一键放行）';
    }
    return '正在建立连接…';
  }

  Color _verdictColor(PeerDiag p) {
    if (p.connAlive) return Colors.green;
    if (p.connectFailures >= 2) return Colors.orange;
    if (p.sinceAnnounceMs > 10000) return Colors.red.shade300;
    return Colors.black54;
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    return Scaffold(
      appBar: AppBar(
        title: const Text('网络诊断'),
        actions: [
          IconButton(
            tooltip: '手动连接对方 IP',
            onPressed: () => showManualConnectDialog(context),
            icon: const Icon(Icons.add),
          ),
          IconButton(onPressed: _refresh, icon: const Icon(Icons.refresh)),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('本机状态',
                      style:
                          TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
                  const SizedBox(height: 6),
                  Text('登录账号：${app.identity?.accountId ?? '未登录'}'),
                  Text('设备名称：${app.identity?.deviceName ?? '-'}'),
                  Text('本机在线：${app.online ? '已上线' : '未上线（去设置里上线）'}'),
                  const SizedBox(height: 4),
                  Text('本机 IP / 网段（检测到 $_nicCount 张网卡）：',
                      style: const TextStyle(color: Colors.black54)),
                  ..._nets.map((n) => Padding(
                        padding: const EdgeInsets.only(left: 8, top: 2),
                        child: Text(n,
                            style: const TextStyle(
                                fontFamily: 'Consolas', fontSize: 13)),
                      )),
                  if (_nicCount > 1)
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Text(
                        '⚠ 本机存在多张网卡：已对每张网卡分别广播上线，'
                        '两张网卡所在网段的设备都应能看到本机。若对方仍看不到，'
                        '请用下方"手动连接"直连对方 IP，或确认两台在同一网段。',
                        style: TextStyle(
                            fontSize: 12,
                            color: Colors.orange.shade800,
                            fontWeight: FontWeight.w500),
                      ),
                    ),
                  const SizedBox(height: 6),
                  const Text('提示：两台设备的 IP 前三段相同才算同一网段；'
                      '不同网段时本程序无法自动发现对方。',
                      style: TextStyle(fontSize: 12, color: Colors.black45)),
                ],
              ),
            ),
          ),
          const SizedBox(height: 8),
          Card(
            child: ListTile(
              leading: Icon(
                _fwAllowed == null
                    ? Icons.help_outline
                    : (_fwAllowed!
                        ? Icons.verified_user_outlined
                        : Icons.gpp_bad_outlined),
                color: _fwAllowed == null
                    ? Colors.black45
                    : (_fwAllowed! ? Colors.green : Colors.orange),
              ),
              title: const Text('本机防火墙入站规则'),
              subtitle: Text(_fwAllowed == null
                  ? '点击下方按钮检测'
                  : (_fwAllowed!
                      ? '已放行：其他设备可以连入本机'
                      : '未放行：其他设备能看到本机但连不进来')),
              trailing: TextButton(
                onPressed: _fwAllowed == null ? _checkFirewall : null,
                child: const Text('检测'),
              ),
            ),
          ),
          const SizedBox(height: 8),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('发现的设备（${_peers.length}）',
                      style:
                          TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
                  const SizedBox(height: 4),
                  if (_peers.isEmpty)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 8),
                      child: Text('暂未发现任何设备。请确认对方也已登录同一账号并上线。'),
                    ),
                  ..._peers.map((p) => Padding(
                        padding: const EdgeInsets.symmetric(vertical: 6),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Expanded(
                                  child: Text('${p.name}   ${p.host}:${p.tcpPort}',
                                      style: const TextStyle(
                                          fontFamily: 'Consolas',
                                          fontSize: 13,
                                          fontWeight: FontWeight.w600)),
                                ),
                                if (_probing.contains(p.deviceId))
                                  const SizedBox(
                                      width: 16,
                                      height: 16,
                                      child: CircularProgressIndicator(
                                          strokeWidth: 2))
                                else
                                  TextButton(
                                    onPressed: () => _probe(p),
                                    child: const Text('测试连接'),
                                  ),
                              ],
                            ),
                            Text('广播：${_ago(p.sinceAnnounceMs)}   '
                                '协议 v${p.version}   '
                                '长连接：${p.connAlive ? '正常' : '无'}   '
                                '连接失败次数：${p.connectFailures}',
                                style: const TextStyle(
                                    fontSize: 12, color: Colors.black54)),
                            Text(_verdict(p),
                                style: TextStyle(
                                    fontSize: 12,
                                    color: _verdictColor(p))),
                            if (_probeResults.containsKey(p.deviceId))
                              Text(
                                  '测试结果：${_probeResults[p.deviceId] ?? '连接成功（端口可达）'}',
                                  style: TextStyle(
                                      fontSize: 12,
                                      color: _probeResults[p.deviceId] == null
                                          ? Colors.green
                                          : Colors.red.shade400)),
                          ],
                        ),
                      )),
                ],
              ),
            ),
          ),
          const SizedBox(height: 8),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('常见结论',
                      style:
                          TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
                  const SizedBox(height: 6),
                  const Text('1. 对方能看到我、我看不到对方 → 对方没收到本机广播：'
                      '检查两台是否同一网段、路由器是否开启 AP/客户端隔离。'),
                  const SizedBox(height: 4),
                  const Text('2. 我能看到对方但显示"连不上" → 对方防火墙未放行入站：'
                      '请在【对方电脑】上打开设置 → 防火墙一键放行。'),
                  const SizedBox(height: 4),
                  const Text('3. 测试连接显示"连接被拒绝" → 对方程序没在监听，'
                      '让对方确认已上线（设置里显示"当前在线"）。'),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
        ],
      ),
    );
  }
}
