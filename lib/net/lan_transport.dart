import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import '../core/constants.dart';
import '../core/logger.dart';
import '../models/identity.dart';
import 'protocol.dart';
import 'transport.dart';

/// 局域网传输实现（V2）：
/// - UDP 广播做设备发现（同 groupId 自动互认，携带协议版本）
/// - V2 设备间建立持久 TCP 长连接：双向 ping/pong 心跳探活，
///   「在线」= 连接真实可达；断线按退避自动重连
/// - V1 设备保持旧行为：按需临时连接，UDP 广播判定在线
/// - 文本/图片带应用层确认（msg_ack）：只有对端 App 真实收到才算发送成功
class LanTransport implements MessageTransport {
  Identity? _me;
  TransportCallbacks? _cb;

  RawDatagramSocket? _udp;
  ServerSocket? _tcp;
  Timer? _announceTimer;
  Timer? _maintainTimer;
  DateTime _nextBcastCalc = DateTime.now();

  /// 上次检查时的本机 IP 签名（网卡名+IP 列表），变化即网络切换
  List<String> _ipSignature = [];

  /// 重建监听中标志（防止重入）
  bool _rebinding = false;

  int _tcpPort = 0;

  /// 缓存的广播目标地址（周期重算，应对换网/休眠唤醒后 IP 变化）
  List<InternetAddress> _bcast = [InternetAddress('255.255.255.255')];

  /// 逐网卡绑定的 UDP 发送通道：解决"双网卡时广播只从路由表选中的
  /// 单张网卡外发、另一张网卡上的对端收不到"的问题。
  /// 每个发送 socket 绑定到某张网卡的 IPv4 后，OS 强制其数据从这张网卡出去。
  final List<_NicSender> _senders = [];

  /// 接收文件/图片的保存目录，由上层在 start 前后设置
  String saveDirectory = '';

  /// 已发现设备：did -> device（含 v1 / v2）
  final Map<String, RemoteDevice> _devices = {};

  /// V2 持久连接：did -> conn
  final Map<String, _PeerConn> _conns = {};

  /// 正在接收的文件：taskId -> _RecvFile
  final Map<String, _RecvFile> _recv = {};

  /// 待确认的应用层 ack：msgId/taskId -> pending
  final Map<String, _PendingAck> _pendingAcks = {};

  @override
  Future<void> start(Identity identity, TransportCallbacks callbacks) async {
    _me = identity;
    _cb = callbacks;

    // 1. TCP 服务（消息/文件）：优先固定端口，占用时回退随机
    await _bindTcpServer();

    // 2. UDP 发现（接收侧监听所有网卡）
    _udp = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4, AppConst.discoveryPort,
        reuseAddress: true, reusePort: false);
    _udp!.broadcastEnabled = true;
    _udp!.listen(_handleUdpEvent);
    log.i('LAN', 'UDP 发现已启动 端口=${AppConst.discoveryPort}');

    // 3. 逐网卡绑定发送通道 + 计算广播目标；记录本机网络签名
    await _rebuildSenders();
    _ipSignature = await _currentIpSignature();

    // 4. 定时广播上线 + 每秒维护（心跳/重连/在线状态刷新/清亡/网络切换重建）
    _announce();
    _announceTimer =
        Timer.periodic(AppConst.announceInterval, (_) => _announce());
    _maintainTimer =
        Timer.periodic(const Duration(seconds: 1), (_) => _maintain());
  }

  @override
  Future<void> stop() async {
    _sendBye();
    _announceTimer?.cancel();
    _maintainTimer?.cancel();
    for (final c in _conns.values) {
      c.socket?.destroy();
    }
    for (final a in _pendingAcks.values) {
      if (!a.completer.isCompleted) {
        a.completer.completeError(StateError('transport stopped'));
      }
    }
    _pendingAcks.clear();
    _conns.clear();
    for (final s in _senders) {
      try {
        s.socket.close();
      } catch (_) {}
    }
    _senders.clear();
    _udp?.close();
    await _tcp?.close();
    _udp = null;
    _tcp = null;
    _devices.clear();
    log.i('LAN', '传输已停止');
  }

  @override
  void refresh() {
    _computeBroadcastTargets();
    _announce();
    // 立即补连缺失的持久连接
    final me = _me;
    if (me == null) return;
    for (final e in _conns.entries) {
      final c = e.value;
      if (c.socket == null && !c.connecting && e.key.compareTo(me.deviceId) > 0) {
        // 仅发起方（对端 did 较大）立即重试
        c.outbound = true;
        c.reconnectAt = DateTime.now();
      }
    }
  }

  // ---------------- UDP 发现 ----------------

  Future<void> _computeBroadcastTargets() async {
    final targets = <InternetAddress>[InternetAddress('255.255.255.255')];
    try {
      for (final ni in await NetworkInterface.list(
          type: InternetAddressType.IPv4, includeLoopback: false)) {
        for (final addr in ni.addresses) {
          final parts = addr.address.split('.');
          if (parts.length == 4) {
            // 假定 /24 子网，定向广播到 x.y.z.255
            targets.add(
                InternetAddress('${parts[0]}.${parts[1]}.${parts[2]}.255'));
          }
        }
      }
    } catch (_) {}
    _bcast = targets;
  }

  List<InternetAddress> _broadcastTargets() => _bcast;

  /// 绑定 TCP 服务：优先固定端口（便于防火墙按端口放行、手动直连），
  /// 被占用时回退随机端口（广播里仍携带真实端口，功能不受影响）。
  Future<void> _bindTcpServer() async {
    try {
      _tcp = await ServerSocket.bind(
          InternetAddress.anyIPv4, AppConst.tcpPort,
          shared: true);
    } on SocketException catch (e) {
      log.w('LAN',
          '固定端口 ${AppConst.tcpPort} 绑定失败(${e.osError?.errorCode})，回退随机端口');
      _tcp = await ServerSocket.bind(InternetAddress.anyIPv4, 0, shared: true);
    }
    _tcpPort = _tcp!.port;
    _tcp!.listen(_handleIncomingSocket, onError: (e) {
      log.e('LAN', 'tcp server error: $e');
    });
    log.i('LAN', 'TCP 服务已启动 端口=$_tcpPort');
  }

  /// 逐网卡重建广播发送通道：给每张启用 IPv4 的网卡绑定一个源 socket。
  /// 绑定后 OS 强制该 socket 的数据从对应网卡出去，双网卡/多网卡下
  /// 各子网的对端都能收到上线广播（修复"广播只从路由表选中的单张网卡外发"）。
  Future<void> _rebuildSenders() async {
    for (final s in _senders) {
      try {
        s.socket.close();
      } catch (_) {}
    }
    _senders.clear();
    await _computeBroadcastTargets();
    try {
      for (final ni in await NetworkInterface.list(
          type: InternetAddressType.IPv4, includeLoopback: false)) {
        for (final addr in ni.addresses) {
          final ip = InternetAddress(addr.address);
          try {
            final s = await RawDatagramSocket.bind(ip, 0);
            s.broadcastEnabled = true;
            _senders.add(_NicSender(s, ip));
          } catch (e) {
            log.w('LAN', '绑定网卡 ${ni.name}(${addr.address}) 发送通道失败: $e');
          }
        }
      }
    } catch (_) {}
    if (_senders.isEmpty) {
      // 兜底：一张都绑不上时用未绑定 socket，至少单网卡仍能广播
      try {
        final s = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
        s.broadcastEnabled = true;
        _senders.add(_NicSender(s, InternetAddress.anyIPv4));
      } catch (_) {}
    }
    log.i('LAN',
        '广播发送通道就绪：${_senders.length} 张网卡 [${_senders.map((s) => s.localIp.address).join(", ")}]');
  }

  /// 通过所有已绑定网卡通道发送一个 UDP 包（逐网卡广播）
  void _broadcast(List<int> packet) {
    final targets = _broadcastTargets();
    for (final sender in _senders) {
      for (final t in targets) {
        try {
          sender.socket.send(packet, t, AppConst.discoveryPort);
        } catch (_) {}
      }
    }
  }

  Map<String, dynamic> _announcePacket(Identity me) => {
        't': 'announce',
        'v': AppConst.protocolVersion,
        'gid': me.groupId,
        'did': me.deviceId,
        'name': me.deviceName,
        'dtype': me.deviceType.name,
        'tcp': _tcpPort,
      };

  /// 当前本机 IPv4 签名（网卡名|IP，排序）
  Future<List<String>> _currentIpSignature() async {
    final out = <String>[];
    try {
      for (final ni in await NetworkInterface.list(
          type: InternetAddressType.IPv4, includeLoopback: false)) {
        for (final a in ni.addresses) {
          out.add('${ni.name}|${a.address}');
        }
      }
    } catch (_) {}
    out.sort();
    return out;
  }

  bool _sameSignature(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  /// 周期检查本机网络是否变化；变化则重建全部监听
  Future<void> _checkNetworkChange() async {
    if (_me == null || _rebinding) return;
    final sig = await _currentIpSignature();
    if (_sameSignature(sig, _ipSignature)) return;
    final hadNetwork = _ipSignature.isNotEmpty;
    _ipSignature = sig;
    log.i('LAN', '本机网络变化: ${sig.join(', ')}');
    if (hadNetwork) {
      await _rebind();
    } else {
      await _computeBroadcastTargets();
      _announce();
    }
  }

  /// 网络切换后重建全部监听：旧 socket 在 Windows 下会静默失效，
  /// 不重建会导致发现与连接双双黑洞（切网后互相看不到、需重启程序）
  Future<void> _rebind() async {
    if (_rebinding) return;
    _rebinding = true;
    try {
      // 关闭旧监听与连接（先摘引用再销毁，避免回调改状态）
      try {
        _udp?.close();
      } catch (_) {}
      _udp = null;
      try {
        await _tcp?.close();
      } catch (_) {}
      _tcp = null;
      for (final s in _senders) {
        try {
          s.socket.close();
        } catch (_) {}
      }
      _senders.clear();
      for (final c in _conns.values) {
        final s = c.socket;
        c.socket = null;
        s?.destroy();
      }
      _conns.clear();
      for (final e in _pendingAcks.entries.toList()) {
        _pendingAcks.remove(e.key);
        if (!e.value.completer.isCompleted) {
          e.value.completer.completeError(StateError('网络已切换'));
        }
      }
      // 重建 TCP 服务（优先固定端口，占用时回退随机；announce 携带真实端口）
      await _bindTcpServer();
      // 重建 UDP 发现接收
      _udp = await RawDatagramSocket.bind(
          InternetAddress.anyIPv4, AppConst.discoveryPort,
          reuseAddress: true, reusePort: false);
      _udp!.broadcastEnabled = true;
      _udp!.listen(_handleUdpEvent);
      // 逐网卡重建发送通道（新网卡 IP 可能已变）
      await _rebuildSenders();
      _announce();
      log.i('LAN', '网络监听已重建 TCP端口=$_tcpPort');
      _emitDevices();
    } catch (e) {
      log.e('LAN', '重建网络监听失败: $e');
    } finally {
      _rebinding = false;
    }
  }

  void _announce() {
    final me = _me;
    if (me == null || _senders.isEmpty) return;
    _broadcast(utf8.encode(jsonEncode(_announcePacket(me))));
  }

  void _sendBye() {
    final me = _me;
    if (me == null || _senders.isEmpty) return;
    final packet = utf8.encode(
        jsonEncode({'t': 'bye', 'gid': me.groupId, 'did': me.deviceId}));
    _broadcast(packet);
  }

  void _handleUdpEvent(RawSocketEvent event) {
    if (event != RawSocketEvent.read) return;
    final dg = _udp?.receive();
    if (dg == null) return;
    final me = _me;
    if (me == null) return;
    try {
      final msg = jsonDecode(utf8.decode(dg.data)) as Map<String, dynamic>;
      if (msg['gid'] != me.groupId) return; // 非同组，忽略
      final did = msg['did'] as String?;
      if (did == null || did == me.deviceId) return; // 自己

      final t = msg['t'];
      if (t == 'bye') {
        _conns.remove(did)?.socket?.destroy();
        if (_devices.remove(did) != null) _emitDevices();
        return;
      }
      if (t != 'announce') return;

      final now = DateTime.now();
      final version = (msg['v'] as int?) ?? 1;
      final host = dg.address.address;
      final tcpPort = (msg['tcp'] as int?) ?? 0;
      final existing = _devices[did];
      if (existing == null) {
        final dev = RemoteDevice(
          deviceId: did,
          name: msg['name'] as String? ?? '设备',
          type: DeviceType.fromString(msg['dtype'] as String?),
          host: host,
          tcpPort: tcpPort,
          lastSeen: now,
          version: version,
        );
        _devices[did] = dev;
        log.i('LAN', '发现设备 ${dev.name} @ $host (v$version)');
        if (version >= AppConst.protocolVersion) {
          final conn = _conns[did] ?? _PeerConn(did: did);
          _conns[did] = conn;
          // did 较小一方为发起方，立即建连；另一方等待被连（8 秒兜底出连）
          if (me.deviceId.compareTo(did) < 0) {
            conn.outbound = true;
            _connectPeer(did);
          }
        }
        // 单播回发一次上线包：让"没收到本机周期广播"的对端
        // （手动连接、跨网段、广播被路由器隔离）立刻反向发现本机
        try {
          _udp?.send(utf8.encode(jsonEncode(_announcePacket(me))), dg.address,
              AppConst.discoveryPort);
        } catch (_) {}
        _emitDevices();
      } else {
        existing.name = msg['name'] as String? ?? existing.name;
        final addrChanged =
            existing.host != host || existing.tcpPort != tcpPort;
        existing.host = host;
        existing.tcpPort = tcpPort;
        existing.version = version;
        existing.lastSeen = now;
        if (version >= AppConst.protocolVersion &&
            !_conns.containsKey(did)) {
          // 连接条目缺失（本端刚重建监听/对端重启）：重建并按角色发起
          final conn = _PeerConn(did: did);
          _conns[did] = conn;
          if (me.deviceId.compareTo(did) < 0) {
            conn.outbound = true;
            _connectPeer(did);
          }
        }
        if (addrChanged) {
          // 广播源地址变化：多网卡对端的各网卡 IP 会交替出现，属正常现象。
          // 持久连接存活时不销毁——活连接比广播源地址更权威；
          // 对端若真换网，心跳几秒内判死后再按新地址重连。
          // 立即销毁会让双网卡场景的连接反复抖动、误报"连不上"。
          final c = _conns[did];
          if (c != null && c.socket == null && c.outbound) {
            c.reconnectAt = DateTime.now();
          }
        } else if (version >= AppConst.protocolVersion &&
            me.deviceId.compareTo(did) < 0) {
          // 有广播但持久连接缺失：立即补连（覆盖心跳超时销毁、漏网等场景）
          final c = _conns[did];
          if (c != null &&
              c.socket == null &&
              !c.connecting &&
              c.reconnectAt == null) {
            _connectPeer(did);
          }
        }
      }
    } catch (e) {
      log.w('LAN', 'UDP 解析失败: $e');
    }
  }

  // ---------------- 在线状态计算 ----------------

  /// 在线 = 持久连接存活；无连接时按 UDP 新鲜度兜底，
  /// 但 V2 连接断开超过宽限期后即使 UDP 仍新鲜也如实显示离线。
  bool _peerOnline(RemoteDevice d, DateTime now) {
    final c = _conns[d.deviceId];
    if (c?.socket != null) return true;
    final udpFresh = now.difference(d.lastSeen) < AppConst.deviceTimeout;
    if (d.version < AppConst.protocolVersion || c == null) return udpFresh;
    if (c.diedAt != null) {
      return udpFresh && now.difference(c.diedAt!) < AppConst.deadGrace;
    }
    // 从未连上：尝试过多次仍失败（对端 TCP 不可达），如实显示离线
    if (c.failures >= 2) return false;
    return udpFresh;
  }

  /// 「能收到广播、却连不上」——用于区分真离线与被防火墙拦截
  bool _peerUnreachable(RemoteDevice d, DateTime now) {
    final c = _conns[d.deviceId];
    if (c?.socket != null) return false; // 已连通
    final udpFresh = now.difference(d.lastSeen) < AppConst.deviceTimeout;
    if (!udpFresh) return false; // 广播都没了，是真离线
    if (d.version < AppConst.protocolVersion) return false;
    if (d.tcpPort <= 0) return false;
    // 反复连不上，或曾连上后断开且超过宽限期
    if (c == null) return false;
    if (c.failures >= 2) return true;
    if (c.diedAt != null &&
        now.difference(c.diedAt!) >= AppConst.deadGrace) {
      return true;
    }
    return false;
  }

  /// 刷新所有设备 online / unreachable 标记；返回是否有变化
  bool _refreshOnlineFlags() {
    var changed = false;
    final now = DateTime.now();
    for (final d in _devices.values) {
      final v = _peerOnline(d, now);
      if (v != d.online) {
        d.online = v;
        changed = true;
      }
      final u = _peerUnreachable(d, now);
      if (u != d.unreachable) {
        d.unreachable = u;
        changed = true;
      }
    }
    return changed;
  }

  void _emitDevices() {
    _refreshOnlineFlags();
    _cb?.onDevicesChanged(_devices.values.toList(growable: false));
  }

  RemoteDevice? deviceById(String id) => _devices[id];

  // ---------------- 诊断支持 ----------------

  /// 当前已绑定、参与逐网卡广播发送的网卡数（诊断用）
  int get broadcastNicCount => _senders.length;

  /// 本机网卡 IPv4 概况（网卡名 + IP/前缀长度）
  Future<List<String>> localNetInfo() async {
    final out = <String>[];
    try {
      for (final ni in await NetworkInterface.list(
          type: InternetAddressType.IPv4, includeLoopback: false)) {
        for (final a in ni.addresses) {
          out.add('${ni.name}   ${a.address}');
        }
      }
    } catch (e) {
      out.add('读取失败：$e');
    }
    if (out.isEmpty) out.add('未发现可用网卡（未联网？）');
    return out;
  }

  /// 已发现设备的诊断快照
  List<PeerDiag> peerDiags() {
    final now = DateTime.now();
    return _devices.values.map((d) {
      final c = _conns[d.deviceId];
      return PeerDiag(
        deviceId: d.deviceId,
        name: d.name,
        host: d.host,
        tcpPort: d.tcpPort,
        version: d.version,
        sinceAnnounceMs: now.difference(d.lastSeen).inMilliseconds,
        connAlive: c?.socket != null,
        connectFailures: c?.failures ?? 0,
        online: d.online,
        unreachable: d.unreachable,
      );
    }).toList(growable: false);
  }

  /// 主动探测某台设备的 TCP 端口能否连通（诊断用）。
  /// 返回 null 表示可连；否则为可读的失败原因。
  Future<String?> probePeer(String did,
      {Duration timeout = const Duration(seconds: 3)}) async {
    final d = _devices[did];
    if (d == null) return '不在发现列表中（本机没收到它的广播）';
    if (d.tcpPort <= 0) return '端口未知（广播数据不完整）';
    if (_conns[did]?.socket != null) return null; // 已有健康长连接
    Socket? s;
    try {
      s = await Socket.connect(d.host, d.tcpPort, timeout: timeout);
      return null;
    } on SocketException catch (e) {
      final code = e.osError?.errorCode ?? 0;
      final refused = code == 10061 || e.osError?.message.contains('拒绝') == true;
      if (refused) {
        return '连接被拒绝（对方端口 $code）：程序在跑但被拦截，多半是对方防火墙未放行';
      }
      return '无法连接：${e.message}（错误码 $code）';
    } catch (e) {
      return '连接超时/失败：$e';
    } finally {
      try {
        s?.destroy();
      } catch (_) {}
    }
  }

  /// 手动按 IP 直连一台设备（广播被过滤 / 跨网段时的兜底）。
  /// 依赖固定 TCP 端口：先单播一次上线包触发双向发现，再主动探测端口可达性。
  /// 返回 null 表示已连上并入列；否则为可读的失败原因。
  Future<String?> connectManual(String host,
      {Duration wait = const Duration(seconds: 4)}) async {
    final me = _me;
    if (me == null) return '请先上线后再手动连接';
    final ip = host.trim();
    if (ip.isEmpty) return '请输入对方 IP 地址';
    InternetAddress addr;
    try {
      addr = InternetAddress(ip);
    } catch (_) {
      return 'IP 地址格式不正确：$ip';
    }
    final announceBytes = utf8.encode(jsonEncode(_announcePacket(me)));

    // 1) 单播一次上线包：触发对方登记本机并回发它的上线广播
    try {
      _udp?.send(announceBytes, addr, AppConst.discoveryPort);
    } catch (_) {}

    // 2) 主动 TCP 探测固定端口，确认可达性（拒绝=对方防火墙未放行）
    Socket? probe;
    try {
      probe = await Socket.connect(ip, AppConst.tcpPort,
          timeout: const Duration(seconds: 4));
    } on SocketException catch (e) {
      final code = e.osError?.errorCode ?? 0;
      if (code == 10061) {
        return '已到达 $ip，但端口 ${AppConst.tcpPort} 被拒绝：'
            '请让对方在「设置 → 防火墙一键放行」完成放行';
      }
      return '无法连接 $ip:${AppConst.tcpPort}（错误码 $code）：'
          '请确认 IP 正确且两台网络可达';
    } catch (e) {
      return '连接 $ip:${AppConst.tcpPort} 超时：'
          '请确认 IP 正确、对方已上线且在同一可达网络';
    } finally {
      try {
        probe?.destroy();
      } catch (_) {}
    }

    // 3) 等待对方回发的上线广播把设备登记进来（期间持续单播鼓励回发）
    final deadline = DateTime.now().add(wait);
    while (DateTime.now().isBefore(deadline)) {
      RemoteDevice? found;
      for (final d in _devices.values) {
        if (d.host == ip) {
          found = d;
          break;
        }
      }
      if (found != null) {
        if (found.version >= AppConst.protocolVersion) {
          final conn = _conns[found.deviceId] ??
              _PeerConn(did: found.deviceId);
          _conns[found.deviceId] = conn;
          conn.outbound = true;
        }
        _connectPeer(found.deviceId);
        _emitDevices();
        return null;
      }
      try {
        _udp?.send(announceBytes, addr, AppConst.discoveryPort);
      } catch (_) {}
      await Future.delayed(const Duration(milliseconds: 400));
    }
    return '端口可达，但未收到对方身份广播：请确认对方已登录同一账号并上线';
  }

  // ---------------- 维护循环（心跳 / 重连 / 清亡） ----------------

  Duration _backoff(int failures) {
    const steps = [1, 2, 4, 5];
    final i = failures.clamp(0, steps.length - 1);
    return Duration(seconds: steps[i]);
  }

  void _maintain() {
    final now = DateTime.now();

    // 1. 心跳与判死
    for (final e in _conns.entries.toList()) {
      final c = e.value;
      final s = c.socket;
      if (s == null) continue;
      if (now.difference(c.lastActivity) > AppConst.connDeadAfter) {
        log.w('LAN', '心跳超时，判定连接失效 did=${e.key}');
        s.destroy(); // 触发 _socketClosed
        continue;
      }
      if (now.isAfter(c.nextPingAt)) {
        try {
          _sendFrame(s, Frame({'type': FrameType.ping}));
        } catch (_) {}
        c.nextPingAt = now.add(AppConst.pingInterval);
      }
    }

    // 2. 出站重连调度
    for (final e in _conns.entries.toList()) {
      final c = e.value;
      if (c.socket != null || c.connecting || !c.outbound) continue;
      final ra = c.reconnectAt;
      if (ra == null || now.isBefore(ra)) continue;
      final d = _devices[e.key];
      if (d == null ||
          now.difference(d.lastSeen) > AppConst.peerFreshWindow) {
        c.reconnectAt = null;
        continue;
      }
      _connectPeer(e.key);
    }

    // 3. 兜底接管：对端 UDP 仍活跃但连接缺失超过宽限期，
    //    无论谁是发起方都尝试出连（防对端重连逻辑卡死导致长期"假离线"）
    for (final e in _conns.entries.toList()) {
      final c = e.value;
      if (c.socket != null || c.connecting) continue;
      if (c.outbound) {
        final ra = c.reconnectAt;
        if (ra != null && now.isBefore(ra)) continue; // 退避等待中
      }
      final d = _devices[e.key];
      if (d == null || d.version < AppConst.protocolVersion) continue;
      if (now.difference(d.lastSeen) > AppConst.deviceTimeout) continue;
      final since = c.diedAt ?? c.created;
      if (now.difference(since) < const Duration(seconds: 12)) continue;
      _connectPeer(e.key);
    }

    // 4. 网络切换检测：本机 IP/网卡变化（热点↔路由器、休眠唤醒）→ 全量重建监听
    //    （Windows 下切网后旧 socket 会静默失效，必须重建才能恢复收发）
    if (now.isAfter(_nextBcastCalc)) {
      _nextBcastCalc = now.add(const Duration(seconds: 3));
      unawaited(_checkNetworkChange());
    }

    // 5. 清理彻底消失的设备（无连接且广播久未出现）
    final removed = <String>[];
    for (final e in _devices.entries) {
      final hasConn = _conns[e.key]?.socket != null;
      if (!hasConn && now.difference(e.value.lastSeen) > AppConst.peerFreshWindow) {
        removed.add(e.key);
      }
    }
    if (removed.isNotEmpty) {
      for (final did in removed) {
        _conns.remove(did)?.socket?.destroy();
        _devices.remove(did);
      }
    }

    // 6. 在线状态可能随宽限期流逝变化
    if (_refreshOnlineFlags() || removed.isNotEmpty) {
      _cb?.onDevicesChanged(_devices.values.toList(growable: false));
    }
  }

  // ---------------- TCP 收发 ----------------

  /// 服务端收到入站连接
  void _handleIncomingSocket(Socket socket) => _listenSocket(socket);

  /// 为 socket 挂接帧解析；knownConn/knownPeer 用于出站持久连接
  void _listenSocket(Socket socket, {_PeerConn? knownConn}) {
    RemoteDevice? peer;
    _PeerConn? conn = knownConn;
    if (conn != null) peer = _devices[conn.did];
    final parser = FrameParser((frame) {
      conn?.touch();
      _onFrame(frame, socket,
          () => peer, (d) => peer = d, (c) => conn = c);
    });
    socket.listen(
      parser.addData,
      onError: (e) {
        log.w('LAN', 'socket error: $e');
        _socketClosed(socket, conn);
      },
      onDone: () => _socketClosed(socket, conn),
      cancelOnError: true,
    );
  }

  /// 持久连接断开：标记、退避重连、通知上层
  void _socketClosed(Socket socket, _PeerConn? conn) {
    if (conn == null) return; // 临时连接，无需维护
    final c = _conns[conn.did];
    if (c == null || !identical(c.socket, socket)) return;
    c.socket = null;
    c.diedAt = DateTime.now();
    c.connecting = false;
    if (c.outbound) {
      c.failures++;
      c.reconnectAt = DateTime.now().add(_backoff(c.failures));
      log.i('LAN', '持久连接断开 did=${conn.did}，'
          '${_backoff(c.failures).inSeconds}s 后重连');
    } else {
      log.i('LAN', '入站连接断开 did=${conn.did}（等待对端重连）');
    }
    // 该 socket 上未完成的确认立即失败
    for (final e in _pendingAcks.entries.toList()) {
      if (identical(e.value.socket, socket)) {
        _pendingAcks.remove(e.key);
        if (!e.value.completer.isCompleted) {
          e.value.completer.completeError(StateError('连接已断开'));
        }
      }
    }
    _emitDevices();
  }

  /// 接受入站持久连接（hello 带 p:true 且对端为 v2）
  void _acceptInbound(String did, Socket socket,
      void Function(_PeerConn) setConn, void Function(RemoteDevice) setPeer) {
    final me = _me!;
    final existing = _conns[did];
    if (existing?.socket != null && me.deviceId.compareTo(did) < 0) {
      // 我方已持有连接且我方 id 较小：保留我方出站连接，拒绝重复入站
      socket.destroy();
      return;
    }
    existing?.socket?.destroy();
    final conn = existing ?? _PeerConn(did: did);
    conn
      ..socket = socket
      ..outbound = false
      ..connecting = false
      ..failures = 0
      ..diedAt = null
      ..touch();
    _conns[did] = conn;
    setConn(conn);
    final dev = _devices[did];
    if (dev != null) setPeer(dev);
    log.i('LAN', '已接受来自 $did 的持久连接');
    _sendAvatarIfAny(socket); // 头像同步（较新者胜出）
    _emitDevices();
  }

  /// 主动建立出站持久连接（v2 对端）
  Future<void> _connectPeer(String did) async {
    final me = _me;
    if (me == null) return;
    final d = _devices[did];
    if (d == null || d.version < AppConst.protocolVersion) return;
    final conn = _conns[did] ?? _PeerConn(did: did);
    _conns[did] = conn;
    if (conn.socket != null || conn.connecting) return;
    conn
      ..connecting = true
      ..outbound = true
      ..reconnectAt = null;
    final targetHost = d.host;
    final targetPort = d.tcpPort;
    try {
      final socket = await Socket.connect(targetHost, targetPort,
          timeout: const Duration(seconds: 5));
      // 连接期间对端广播源地址可能交替（多网卡）：连接成功即证明可达，不作废；
      // 仅设备消失或端口变化（对端重启换了端口）才弃用本次连接
      final cur = _devices[did];
      if (cur == null || cur.tcpPort != targetPort) {
        socket.destroy();
        conn.connecting = false;
        return;
      }
      socket.add(_helloFrame(persist: true).encode());
      conn
        ..socket = socket
        ..connecting = false
        ..failures = 0
        ..diedAt = null
        ..touch();
      _listenSocket(socket, knownConn: conn);
      log.i('LAN', '已与 ${d.name} 建立持久连接');
      _sendAvatarIfAny(socket); // 头像同步（较新者胜出）
      _emitDevices();
    } catch (_) {
      conn.connecting = false;
      conn.failures += 1;
      conn.reconnectAt = DateTime.now().add(_backoff(conn.failures));
    }
  }

  void _onFrame(Frame frame, Socket socket, RemoteDevice? Function() getPeer,
      void Function(RemoteDevice) setPeer, void Function(_PeerConn) setConn) {
    final me = _me;
    if (me == null) return;

    switch (frame.type) {
      case FrameType.hello:
        if (frame.header['gid'] != me.groupId) {
          socket.destroy();
          return;
        }
        final did = frame.header['did'] as String? ?? '';
        if (did.isEmpty) return;
        final persist = (frame.header['p'] as bool?) ?? false;
        final dev = _devices[did];
        if (persist && dev != null && dev.version >= AppConst.protocolVersion) {
          _acceptInbound(did, socket, setConn, setPeer);
          return;
        }
        // 临时连接（v1 对端或普通发送）：仅用于本次收发
        setPeer(dev ??
            RemoteDevice(
              deviceId: did,
              name: frame.header['name'] as String? ?? '设备',
              type: DeviceType.fromString(frame.header['dtype'] as String?),
              host: socket.remoteAddress.address,
              tcpPort: (frame.header['tcp'] as int?) ?? 0,
              lastSeen: DateTime.now(),
            ));
        break;

      case FrameType.ping:
        _sendFrame(socket, Frame({'type': FrameType.pong}));
        break;

      case FrameType.pong:
        break; // lastActivity 已由监听层刷新

      case FrameType.msgAck:
        final id = frame.header['id'] as String? ?? '';
        final a = _pendingAcks.remove(id);
        if (a != null && !a.completer.isCompleted) a.completer.complete();
        break;

      case FrameType.avatar:
        final bytes = frame.body;
        if (bytes == null || bytes.isEmpty) break;
        final ts = (frame.header['ts'] as int?) ?? 0;
        _cb?.onAvatarSync?.call(bytes, ts);
        break;

      case FrameType.fileAck:
        final id = frame.header['id'] as String? ?? '';
        final a = _pendingAcks.remove(id);
        if (a != null && !a.completer.isCompleted) a.completer.complete();
        break;

      case FrameType.text:
        final peer = getPeer();
        if (peer == null) return;
        _cb?.onText(
          peer,
          frame.header['id'] as String? ?? '',
          frame.header['text'] as String? ?? '',
          DateTime.fromMillisecondsSinceEpoch(
              (frame.header['ts'] as int?) ?? DateTime.now().millisecondsSinceEpoch),
        );
        // 应用层确认：告知发送方“本端 App 已真实收到”
        _sendFrame(socket,
            Frame({'type': FrameType.msgAck, 'id': frame.header['id'] ?? ''}));
        break;

      case FrameType.image:
        final peer = getPeer();
        if (peer == null || frame.body == null) return;
        final msgId = frame.header['id'] as String? ?? '';
        _saveBytes(frame.header['name'] as String? ?? 'image.png', frame.body!)
            .then((path) {
          _sendFrame(socket, Frame({'type': FrameType.msgAck, 'id': msgId}));
          _cb?.onImage(peer, msgId, path,
              frame.header['name'] as String? ?? 'image.png');
        });
        break;

      case FrameType.fileOffer:
        final peer = getPeer();
        if (peer == null) return;
        final taskId = frame.header['id'] as String? ?? '';
        final name = frame.header['name'] as String? ?? 'file';
        final size = (frame.header['size'] as int?) ?? 0;
        _beginRecvFile(taskId, name, size);
        _cb?.onFileOffer(peer, taskId, name, size);
        break;

      case FrameType.fileChunk:
        final taskId = frame.header['id'] as String? ?? '';
        final rf = _recv[taskId];
        if (rf != null && frame.body != null) {
          final body = frame.body!;
          // 文件尚未就绪（offer 与 chunk 同批到达）时先缓冲，不丢块
          if (rf.sink != null) {
            rf.sink!.add(body);
          } else {
            rf.early.add(body);
          }
          rf.received += body.length;
          _cb?.onFileProgress(taskId, rf.received, rf.total);
        }
        break;

      case FrameType.fileEnd:
        final taskId = frame.header['id'] as String? ?? '';
        _finishRecvFile(taskId, socket);
        break;

      case FrameType.loginGrant:
        // 本设备被已登录手机授权登录
        final granted = Identity(
          accountId: frame.header['accountId'] as String? ?? '',
          groupId: frame.header['gid'] as String? ?? '',
          deviceId: me.deviceId,
          deviceName: me.deviceName,
          deviceType: me.deviceType,
        );
        _sendFrame(socket, Frame({'type': FrameType.loginAck, 'ok': true}));
        _cb?.onLoginGranted(granted);
        break;
    }
  }

  Future<void> _beginRecvFile(String taskId, String name, int total) async {
    // 先同步占位：offer 与首批 chunk 常在同一次 TCP 读事件里到达，
    // 异步建文件期间到达的块须缓冲而非丢弃（v1 的隐藏丢块缺陷）
    final rf = _RecvFile(total: total);
    _recv[taskId] = rf;
    try {
      rf.path = await _allocPath(name);
      final file = File(rf.path);
      await file.parent.create(recursive: true);
      rf.sink = file.openWrite();
      for (final b in rf.early) {
        rf.sink!.add(b);
      }
      rf.early.clear();
      rf.ready.complete();
      log.i('LAN', '开始接收文件 $name -> ${rf.path}');
    } catch (e) {
      if (!rf.ready.isCompleted) rf.ready.completeError(e);
    }
  }

  Future<void> _finishRecvFile(String taskId, Socket socket) async {
    final rf = _recv.remove(taskId);
    if (rf == null) return;
    try {
      await rf.ready.future; // 等待文件就绪（含早到块补写）
      await rf.sink!.flush();
      await rf.sink!.close();
      _sendFrame(socket, Frame({'type': FrameType.fileAck, 'id': taskId, 'ok': true}));
      _cb?.onFileDone(taskId, rf.path);
      log.i('LAN', '文件接收完成 ${rf.path}');
    } catch (e) {
      _cb?.onFileError(taskId, '$e');
    }
  }

  // ---------------- TCP 发送 ----------------

  Frame _helloFrame({bool persist = false}) {
    final me = _me!;
    return Frame({
      'type': FrameType.hello,
      'v': AppConst.protocolVersion,
      if (persist) 'p': true,
      'gid': me.groupId,
      'did': me.deviceId,
      'name': me.deviceName,
      'dtype': me.deviceType.name,
      'tcp': _tcpPort,
    });
  }

  void _sendFrame(Socket socket, Frame frame) => socket.add(frame.encode());

  // ---------------- 头像同步 ----------------

  /// 从头像文件名解析时间戳（`avatar_<ms>.<ext>`）
  int avatarTimestamp(String? path) {
    if (path == null) return 0;
    final base = p.basenameWithoutExtension(path);
    final i = base.indexOf('_');
    if (i < 0) return 0;
    return int.tryParse(base.substring(i + 1)) ?? 0;
  }

  /// 向指定持久连接发送本机头像（如有）
  Future<void> _sendAvatarIfAny(Socket socket) async {
    final me = _me;
    final path = me?.avatarPath;
    if (me == null || path == null || path.isEmpty) return;
    try {
      final bytes = await File(path).readAsBytes();
      if (bytes.isEmpty) return;
      _sendFrame(socket, Frame({
        'type': FrameType.avatar,
        'did': me.deviceId,
        'ts': avatarTimestamp(path),
        'bodyLen': bytes.length,
      }, bytes));
    } catch (_) {}
  }

  /// 本机头像更新后：向所有已连接的 v2 设备广播
  Future<void> syncAvatar() async {
    for (final e in _conns.entries) {
      final s = e.value.socket;
      if (s != null) await _sendAvatarIfAny(s);
    }
  }

  bool _isPersistSocket(Socket socket, String did) =>
      identical(_conns[did]?.socket, socket);

  /// 取发送通道：优先复用持久连接；否则临时连接（v1 对端唯一路径）
  Future<Socket> _socketFor(RemoteDevice to) async {
    final s = _conns[to.deviceId]?.socket;
    if (s != null) return s;
    return _tempSocket(to);
  }

  /// 独立临时连接（文件传输专用，避免大流量与心跳/消息互相阻塞，
  /// 也避免传完误关持久连接）
  Future<Socket> _tempSocket(RemoteDevice to) async {
    final socket = await Socket.connect(to.host, to.tcpPort,
        timeout: const Duration(seconds: 5));
    socket.add(_helloFrame().encode());
    // 临时连接同样需要解析回传的 msg_ack / file_ack 帧
    _listenSocket(socket);
    return socket;
  }

  @override
  Future<void> sendText(RemoteDevice to, String msgId, String text) async {
    final socket = await _socketFor(to);
    final persist = _isPersistSocket(socket, to.deviceId);
    final ack = Completer<void>();
    // 仅 v2 对端会回 msg_ack；v1 对端无法确认，维持旧行为
    final needAck = to.version >= AppConst.protocolVersion;
    if (needAck) _pendingAcks[msgId] = _PendingAck(ack, socket);
    try {
      _sendFrame(
          socket,
          Frame({
            'type': FrameType.text,
            'id': msgId,
            'text': text,
            'ts': DateTime.now().millisecondsSinceEpoch,
          }));
      await socket.flush();
      if (needAck) {
        await ack.future.timeout(const Duration(seconds: 5));
      }
    } on TimeoutException {
      throw TimeoutException('对方未确认接收（可能已离线）');
    } finally {
      _pendingAcks.remove(msgId);
      if (!persist) {
        try {
          await socket.close();
        } catch (_) {}
      }
    }
  }

  @override
  Future<void> sendImage(
      RemoteDevice to, String msgId, Uint8List bytes, String name) async {
    final socket = await _socketFor(to);
    final persist = _isPersistSocket(socket, to.deviceId);
    final ack = Completer<void>();
    final needAck = to.version >= AppConst.protocolVersion;
    if (needAck) _pendingAcks[msgId] = _PendingAck(ack, socket);
    try {
      _sendFrame(
          socket,
          Frame({
            'type': FrameType.image,
            'id': msgId,
            'name': name,
            'ts': DateTime.now().millisecondsSinceEpoch,
            'bodyLen': bytes.length,
          }, bytes));
      await socket.flush();
      if (needAck) {
        await ack.future.timeout(const Duration(seconds: 10));
      }
    } on TimeoutException {
      throw TimeoutException('对方未确认接收（可能已离线）');
    } finally {
      _pendingAcks.remove(msgId);
      if (!persist) {
        try {
          await socket.close();
        } catch (_) {}
      }
    }
  }

  @override
  Future<void> sendFile(
    RemoteDevice to,
    String taskId,
    String filePath,
    String fileName,
    int size, {
    required void Function(int sent, int total) onProgress,
  }) async {
    Socket? socket;
    try {
      // 文件传输走独立临时连接，不占用持久连接
      socket = await _tempSocket(to);
      _sendFrame(
          socket,
          Frame({
            'type': FrameType.fileOffer,
            'id': taskId,
            'name': fileName,
            'size': size,
          }));
      final ack = Completer<void>();
      // 旧版接收方同样会回 file_ack，因此无条件等待
      _pendingAcks[taskId] = _PendingAck(ack, socket);
      var sent = 0;
      var sinceFlush = 0;
      final raf = await File(filePath).open();
      try {
        while (sent < size) {
          final remain = size - sent;
          final n =
              remain < AppConst.fileChunkSize ? remain : AppConst.fileChunkSize;
          final chunk = await raf.read(n);
          if (chunk.isEmpty) break;
          _sendFrame(
              socket,
              Frame({
                'type': FrameType.fileChunk,
                'id': taskId,
                'bodyLen': chunk.length,
              }, chunk));
          sent += chunk.length;
          onProgress(sent, size);
          // 每 4 块（1MB）flush 一次：既提供回压又避免逐块等待
          sinceFlush++;
          if (sinceFlush >= 4) {
            await socket.flush();
            sinceFlush = 0;
          }
        }
      } finally {
        await raf.close();
      }
      _sendFrame(socket, Frame({'type': FrameType.fileEnd, 'id': taskId}));
      await socket.flush();
      // 等待对端落盘确认（超时随文件大小放宽）
      final timeoutMs = 15000 + size ~/ 200; // ≈200KB/s 下限 + 15s
      await ack.future.timeout(Duration(milliseconds: timeoutMs));
      await socket.close();
      log.i('LAN', '文件发送完成 $fileName');
    } catch (e) {
      socket?.destroy();
      rethrow;
    } finally {
      _pendingAcks.remove(taskId);
    }
  }

  // ---------------- 扫码登录 ----------------

  ServerSocket? _loginServer;

  @override
  Future<Map<String, dynamic>> startLoginBeacon(
      void Function(Identity granted) onGranted) async {
    await _loginServer?.close();
    _loginServer = await ServerSocket.bind(InternetAddress.anyIPv4, 0);
    final nonce = DateTime.now().millisecondsSinceEpoch.toString();
    _loginServer!.listen((socket) {
      final parser = FrameParser((frame) {
        if (frame.type == FrameType.loginGrant) {
          final me = _me;
          final granted = Identity(
            accountId: frame.header['accountId'] as String? ?? '',
            groupId: frame.header['gid'] as String? ?? '',
            deviceId: me?.deviceId ?? '',
            deviceName: me?.deviceName ?? 'PC',
            deviceType: me?.deviceType ?? DeviceType.windows,
          );
          _sendFrame(socket, Frame({'type': FrameType.loginAck, 'ok': true}));
          socket.flush().then((_) => socket.close());
          onGranted(granted);
        }
      });
      socket.listen(parser.addData);
    });
    final host = await _primaryIpv4();
    return {'host': host, 'port': _loginServer!.port, 'nonce': nonce};
  }

  @override
  Future<void> grantLogin(String host, int port, Identity identity) async {
    final socket =
        await Socket.connect(host, port, timeout: const Duration(seconds: 8));
    _sendFrame(
        socket,
        Frame({
          'type': FrameType.loginGrant,
          'accountId': identity.accountId,
          'gid': identity.groupId,
        }));
    await socket.flush();
    await Future.delayed(const Duration(milliseconds: 500));
    await socket.close();
  }

  Future<String> _primaryIpv4() async {
    try {
      for (final ni in await NetworkInterface.list(
          type: InternetAddressType.IPv4, includeLoopback: false)) {
        for (final a in ni.addresses) {
          if (!a.isLoopback) return a.address;
        }
      }
    } catch (_) {}
    return '127.0.0.1';
  }

  // ---------------- 文件保存路径 ----------------

  Future<String> _allocPath(String name) async {
    final dir = saveDirectory.isEmpty ? Directory.systemTemp.path : saveDirectory;
    var candidate = p.join(dir, name);
    var i = 1;
    final base = p.basenameWithoutExtension(name);
    final ext = p.extension(name);
    while (await File(candidate).exists()) {
      candidate = p.join(dir, '$base($i)$ext');
      i++;
    }
    return candidate;
  }

  Future<String> _saveBytes(String name, Uint8List bytes) async {
    final path = await _allocPath(name);
    final f = File(path);
    await f.parent.create(recursive: true);
    await f.writeAsBytes(bytes);
    return path;
  }
}

/// 诊断快照：某台已发现设备的可见性与连通情况
class PeerDiag {
  final String deviceId;
  final String name;
  final String host;
  final int tcpPort;
  final int version;

  /// 距上次收到对方 UDP 广播的毫秒数
  final int sinceAnnounceMs;
  final bool connAlive;
  final int connectFailures;
  final bool online;
  final bool unreachable;

  const PeerDiag({
    required this.deviceId,
    required this.name,
    required this.host,
    required this.tcpPort,
    required this.version,
    required this.sinceAnnounceMs,
    required this.connAlive,
    required this.connectFailures,
    required this.online,
    required this.unreachable,
  });
}

/// 逐网卡绑定的 UDP 发送通道（一张网卡一个源 socket）
class _NicSender {
  final RawDatagramSocket socket;
  final InternetAddress localIp;
  _NicSender(this.socket, this.localIp);
}

/// V2 持久连接状态
class _PeerConn {
  final String did;
  final DateTime created = DateTime.now();
  Socket? socket;

  /// 是否由本端主动发起（断开后由本端负责重连）
  bool outbound = false;
  bool connecting = false;
  DateTime lastActivity = DateTime.now();
  DateTime nextPingAt =
      DateTime.now().add(AppConst.pingInterval);
  DateTime? reconnectAt;
  DateTime? diedAt;
  int failures = 0;

  _PeerConn({required this.did});

  void touch() => lastActivity = DateTime.now();
}

/// 待接收的应用层确认
class _PendingAck {
  final Completer<void> completer;
  final Socket socket;
  _PendingAck(this.completer, this.socket);
}

class _RecvFile {
  String path = '';
  int total;
  final Completer<void> ready = Completer<void>();
  IOSink? sink;

  /// 文件就绪前缓冲的早到块
  final List<Uint8List> early = [];
  int received = 0;
  _RecvFile({required this.total});
}
