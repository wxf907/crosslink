import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:provider/provider.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../state/app_state.dart';

/// 待登录设备（通常是 PC）：展示二维码，等待已登录手机扫码授权。
class QrShowPage extends StatefulWidget {
  const QrShowPage({super.key});

  @override
  State<QrShowPage> createState() => _QrShowPageState();
}

class _QrShowPageState extends State<QrShowPage> {
  String? _qrData;
  String? _error;
  String? _host;
  int? _port;
  List<String> _allIps = [];

  /// 进入页面时的登录态：只有"从未登录变为已登录"（扫码授权成功）才自动关闭；
  /// 已登录状态下从设置进入时保持页面打开（此前一进就被自动关掉）
  bool _wasLoggedIn = false;

  @override
  void initState() {
    super.initState();
    _wasLoggedIn = context.read<AppState>().loggedIn;
    _prepare();
  }

  Future<void> _prepare() async {
    try {
      final info = await context.read<AppState>().startLoginBeacon();
      final data = jsonEncode({
        'v': 1,
        'act': 'login',
        'host': info['host'],
        'port': info['port'],
        'nonce': info['nonce'],
      });
      // 本机地址自检：广播用 IP + 全部 IPv4，便于排查网段/防火墙问题
      final ips = <String>[];
      try {
        for (final ni in await NetworkInterface.list(
            type: InternetAddressType.IPv4, includeLoopback: false)) {
          for (final a in ni.addresses) {
            ips.add(a.address);
          }
        }
      } catch (_) {}
      if (mounted) {
        setState(() {
          _qrData = data;
          _host = info['host'] as String?;
          _port = info['port'] as int?;
          _allIps = ips;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    // 未登录状态进入、扫码授权成功后（loggedIn 变 true）自动关闭本页
    final loggedIn = context.watch<AppState>().loggedIn;
    if (!_wasLoggedIn && loggedIn) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) Navigator.of(context).maybePop();
      });
    }

    return Scaffold(
      appBar: AppBar(title: const Text('扫码登录')),
      body: Center(
        child: _error != null
            ? Text('二维码生成失败：$_error')
            : _qrData == null
                ? const CircularProgressIndicator()
                : Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(12),
                          boxShadow: [
                            BoxShadow(
                                color: Colors.black.withValues(alpha: 0.08),
                                blurRadius: 12)
                          ],
                        ),
                        child: QrImageView(data: _qrData!, size: 240),
                      ),
                      const SizedBox(height: 20),
                      const Text('请使用已登录的手机扫描此二维码',
                          style: TextStyle(fontSize: 15)),
                      const SizedBox(height: 6),
                      const Text('需与本机处于同一局域网',
                          style: TextStyle(color: Colors.black45)),
                      if (_host != null) ...[
                        const SizedBox(height: 10),
                        Text('连接地址：$_host:$_port',
                            style: const TextStyle(fontSize: 12)),
                        if (_allIps.isNotEmpty)
                          Text('本机 IPv4：${_allIps.join("、")}',
                              style: const TextStyle(
                                  fontSize: 12, color: Colors.black45)),
                        const SizedBox(height: 4),
                        if (_allIps.length > 1)
                          Text(
                            '注意：本机有多个 IP（多网卡），二维码默认用第一个；'
                            '若手机连不上，请确认手机所连 WiFi 与上面某个 IP 同网段。',
                            style: TextStyle(
                                fontSize: 11, color: Colors.orange.shade800),
                          ),
                        const Text(
                          '手机扫后若报"无法连接"：①核对手机 IP 与上面是否同网段；'
                          '②关闭路由器"AP/无线隔离"；③电脑防火墙放行 CrossLink',
                          style: TextStyle(fontSize: 11, color: Colors.black38),
                        ),
                      ],
                      if (_wasLoggedIn) ...[
                        const SizedBox(height: 6),
                        const Text('（本机已登录；此二维码用于在其他电脑上授权登录）',
                            style:
                                TextStyle(color: Colors.black38, fontSize: 12)),
                      ],
                    ],
                  ),
      ),
    );
  }
}

/// 已登录设备（手机）：扫描待登录设备的二维码并下发登录凭证。
class QrScanPage extends StatefulWidget {
  const QrScanPage({super.key});

  @override
  State<QrScanPage> createState() => _QrScanPageState();
}

class _QrScanPageState extends State<QrScanPage> {
  bool _handled = false;
  String _status = '将取景框对准电脑上的二维码';
  DateTime _lastForeignNotice = DateTime.fromMillisecondsSinceEpoch(0);

  void _setStatus(String s) {
    if (mounted) setState(() => _status = s);
  }

  Future<void> _onDetect(BarcodeCapture capture) async {
    if (_handled) return;
    for (final b in capture.barcodes) {
      final raw = b.rawValue;
      if (raw == null) continue;

      Map<String, dynamic>? j;
      try {
        j = jsonDecode(raw) as Map<String, dynamic>;
      } catch (_) {
        j = null;
      }
      if (j == null || j['act'] != 'login') {
        // 非本应用二维码：给出可见反馈（节流 3 秒一次）
        final now = DateTime.now();
        if (now.difference(_lastForeignNotice) >
            const Duration(seconds: 3)) {
          _lastForeignNotice = now;
          _setStatus('检测到二维码，但不是 CrossLink 登录码');
        }
        continue;
      }

      _handled = true;
      _setStatus('已识别，正在连接对方设备…');
      final host = j['host'] as String;
      final port = j['port'] as int;
      try {
        await context
            .read<AppState>()
            .grantLoginTo(host, port)
            .timeout(const Duration(seconds: 6));
        if (mounted) {
          Navigator.of(context).pop();
          ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('已为对方设备授权登录')));
        }
      } catch (e) {
        _handled = false; // 允许重试
        _setStatus('连接失败，可重新对准再试');
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
              content: Text('授权失败：无法连接 $host:$port。'
                  '请确认手机与电脑在同一局域网，且电脑防火墙已放行 CrossLink。'),
              duration: const Duration(seconds: 5)));
        }
      }
      return;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('扫一扫')),
      body: Stack(
        alignment: Alignment.center,
        children: [
          MobileScanner(onDetect: _onDetect),
          Container(
            width: 240,
            height: 240,
            decoration: BoxDecoration(
              border: Border.all(color: Colors.white, width: 2),
              borderRadius: BorderRadius.circular(12),
            ),
          ),
          Positioned(
            bottom: 60,
            left: 24,
            right: 24,
            child: Text(
              _status,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white, fontSize: 15),
            ),
          ),
        ],
      ),
    );
  }
}
