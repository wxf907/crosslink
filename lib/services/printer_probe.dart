import 'dart:async';
import 'dart:io';

/// 打印机在线探测——替代"驱动级查询"的轻量方案。
///
/// 背景：对离线网络打印机调 DeviceCapabilitiesW（驱动能力查询）会触发
/// 驱动去连接设备，Windows 弹"等待连接"对话框并长时间阻塞；而打印服务
/// （spooler）对关机的网络打印机只报缓存状态（往往仍是"就绪"）。
///
/// 本探测完全不经过驱动，无弹窗、无阻塞：
/// - TCP/IP 端口（`IP_x.x.x.x` / 纯 IP）：直连打印机 9100(RAW)/631(IPP) 端口
/// - WSD 端口（`WSD-<uuid>`）：发 WS-Discovery 探测报文（UDP 组播），按设备
///   UUID 匹配应答——这正是 Windows 判断 WSD 设备在不在的同一机制
/// - USB 等本地端口：返回 null，交给 spooler 状态位判断
class PrinterProbe {
  static final _ipRe = RegExp(r'(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})');

  /// 探测结果：true=在线 false=离线 null=无法探测（用 spooler 状态位兜底）
  static Future<bool?> online(String portName) async {
    final p = portName.trim();
    if (p.isEmpty) return null;
    if (p.toUpperCase().startsWith('WSD-')) {
      return _wsdOnline(p.substring(4));
    }
    final m = _ipRe.firstMatch(p);
    if (m != null) {
      return _tcpOnline(m.group(1)!);
    }
    return null; // USB001 等本地端口
  }

  /// TCP 直连打印机标准端口：9100(RAW) 几乎所有网络打印机都开，
  /// 631(IPP) 作为兜底。各 400ms 超时，全异步不阻塞 UI。
  static Future<bool> _tcpOnline(String ip) async {
    for (final port in const [9100, 631]) {
      try {
        final s = await Socket.connect(ip, port,
            timeout: const Duration(milliseconds: 400));
        s.destroy();
        return true;
      } catch (_) {}
    }
    return false;
  }

  /// WS-Discovery 探测：向组播组 239.255.255.250:3702 发 Probe，
  /// 在窗口期内收应答，按端口名里的 UUID 匹配是不是这台打印机。
  /// 设备开机必答（这正是 WSD 协议的存在意义），不答即离线。
  static Future<bool?> _wsdOnline(String uuid) async {
    const group = '239.255.255.250';
    const port = 3702;
    final uid = DateTime.now().microsecondsSinceEpoch.toRadixString(16);
    final msg = '<?xml version="1.0" encoding="utf-8"?>'
        '<s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope" '
        'xmlns:a="http://schemas.xmlsoap.org/ws/2004/08/addressing" '
        'xmlns:d="http://schemas.xmlsoap.org/ws/2005/04/discovery">'
        '<s:Header>'
        '<a:Action>http://schemas.xmlsoap.org/ws/2005/04/discovery/Probe</a:Action>'
        '<a:MessageID>urn:uuid:00000000-0000-0000-0000-$uid</a:MessageID>'
        '<a:To>urn:schemas-xmlsoap-org:ws:2005:04:discovery</a:To>'
        '</s:Header>'
        '<s:Body><d:Probe/></s:Body>'
        '</s:Envelope>';

    RawDatagramSocket? s;
    try {
      s = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      s.joinMulticast(InternetAddress(group));
    } catch (_) {
      s?.close();
      return null; // 组播环境不可用，不妄下结论
    }

    final completer = Completer<bool>();
    final want = uuid.toLowerCase();
    Timer? finishTimer;
    void finish(bool v) {
      if (!completer.isCompleted) completer.complete(v);
    }

    finishTimer = Timer(const Duration(milliseconds: 900), () => finish(false));
    final sub = s.listen(
      (e) {
        if (e == RawSocketEvent.read) {
          final dg = s!.receive();
          if (dg != null) {
            final text = String.fromCharCodes(dg.data).toLowerCase();
            if (text.contains(want)) {
              finishTimer?.cancel();
              finish(true);
            }
          }
        }
      },
      onError: (_) {
        finishTimer?.cancel();
        finish(false);
      },
    );

    // 连发两次提高命中率（WS-Discovery 建议重发）
    for (var i = 0; i < 2; i++) {
      s.send(msg.codeUnits, InternetAddress(group), port);
      if (i == 0) await Future<void>.delayed(const Duration(milliseconds: 150));
    }

    final r = await completer.future;
    unawaited(sub.cancel());
    s.close();
    return r;
  }
}
