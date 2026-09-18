import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import '../core/constants.dart';
import '../core/logger.dart';
import '../models/app_settings.dart';
import '../models/identity.dart';
import '../models/message.dart';
import '../models/transfer_task.dart';
import '../net/lan_transport.dart';
import '../net/transport.dart';
import '../services/android_public_store.dart';
import '../services/identity_service.dart';
import '../services/print_share_service.dart';
import '../services/printing/print_service.dart';
import '../services/print_engine.dart';
import '../services/storage_service.dart';

/// 设备在列表中的展示视图（合并在线设备 + 历史会话）。
///
/// 除了连接状态，还承载"一眼认出是哪台机器"所需的信息：
/// 用途角色 [role]、局域网 [host]、本机备注 [alias]、未读数 [unread]
/// 与最近一条收到的消息 [lastIncoming]。
///
/// 派生逻辑（[displayName]/[colorSeed]/[initial]/[ipTail]/[activityLabel]）
/// 全部写成纯函数放在这里而不是 widget 里，为的是能脱离界面直接单测。
class PeerView {
  final String id;

  /// 对方自己上报的设备名（由那台机器自行决定）
  final String name;
  final DeviceType type;

  /// 用途角色；对端为旧版本时是 [DeviceRole.unset]
  final DeviceRole role;
  final bool online;

  /// 能收到对方广播但 TCP 连不上（多半是对方防火墙未放行）
  final bool unreachable;

  /// 对端局域网 IP；离线且从未见过时为 null
  final String? host;

  /// 本机给这台设备起的备注名（空串=没起）
  final String alias;

  /// 未读消息条数（仅统计收到方向）
  final int unread;

  /// 最近一条"收到的"消息，用于副标题预览
  final ChatMessage? lastIncoming;

  PeerView({
    required this.id,
    required this.name,
    required this.type,
    required this.online,
    this.role = DeviceRole.unset,
    this.unreachable = false,
    this.host,
    this.alias = '',
    this.unread = 0,
    this.lastIncoming,
  });

  /// 列表展示名：我起的备注优先，其次对方自报名
  String get displayName => alias.isNotEmpty ? alias : name;

  /// 稳定配色种子：FNV-1a 哈希 deviceId。
  ///
  /// 之所以哈希 id 而不是哈希名字——id 由 MachineGuid / ANDROID_ID 派生，
  /// 重装系统前都不会变，且与设备一一对应；而名字用户可以随时改成
  /// 任何重名的字符串。哈希结果取模交给界面层决定调色板。
  int get colorSeed {
    const fnvPrime = 0x01000193;
    var hash = 0x811c9dc5;
    for (final u in id.codeUnits) {
      hash = (hash ^ u) * fnvPrime & 0xFFFFFFFF;
    }
    return hash;
  }

  /// 徽标首字：中文名取第一个汉字，英文名取首字母并大写。
  /// 空名兜底为 '?'，避免出现空白圆。用 runes 取码点，
  /// 免得为一个字引入 package:characters 依赖。
  String get initial {
    final n = displayName.trim();
    if (n.isEmpty) return '?';
    final c = String.fromCharCodes(n.runes.take(1));
    return RegExp(r'^[a-z]$').hasMatch(c) ? c.toUpperCase() : c;
  }

  /// IP 尾段（`.23`），用于同型号设备的技术兜底识别；无 IP 时返回空串
  String get ipTail {
    final h = host;
    if (h == null || h.isEmpty) return '';
    final i = h.lastIndexOf('.');
    return i < 0 ? h : '.${h.substring(i + 1)}';
  }

  /// 副标题里的"最近动态"：`3分钟前 · 发来1个文件`；无消息时为空串
  String activityLabel(DateTime now) {
    final m = lastIncoming;
    if (m == null) return '';
    final secs = now.difference(m.time).inSeconds;
    final when = secs < 60
        ? '刚刚'
        : secs < 3600
            ? '${secs ~/ 60}分钟前'
            : secs < 86400
                ? '${secs ~/ 3600}小时前'
                : '${secs ~/ 86400}天前';
    final what = switch (m.kind) {
      MessageKind.image => '发来图片',
      MessageKind.file => '发来文件',
      MessageKind.system => '发来通知',
      MessageKind.text => '发来消息',
    };
    return '$when · $what';
  }
}

/// 未读条数：只数「收到方向、且时间晚于已读水位」的消息。
///
/// 抽成顶层纯函数的原因——未读算错是最容易伤到用户的一种 bug
/// （满屏红点或该红不红），必须能脱离 StorageService/平台插件直接单测。
/// 边界取严格大于：水位等于该条时间戳时视为已读，避免"刚点开又亮回去"。
int countIncomingUnread(List<ChatMessage> msgs, int lastReadMs) {
  var n = 0;
  for (final m in msgs) {
    if (m.outgoing) continue;
    if (m.time.millisecondsSinceEpoch > lastReadMs) n++;
  }
  return n;
}

/// 最后一条"收到的"消息，用于列表副标题预览。
/// 会话按时间追加，正向扫一遍取最后一条即可（不依赖排序假设里的"末尾"）。
ChatMessage? lastIncomingMessage(List<ChatMessage> msgs) {
  ChatMessage? last;
  for (final m in msgs) {
    if (!m.outgoing) last = m;
  }
  return last;
}

/// 应用全局状态与业务编排中心。
class AppState extends ChangeNotifier {
  final StorageService storage = StorageService();
  final LanTransport _transport = LanTransport();
  final _uuid = const Uuid();

  Identity? identity;
  late AppSettings settings;
  bool online = false;

  /// 在线设备：id -> device
  final Map<String, RemoteDevice> _online = {};

  /// 会话消息：peerId -> 消息列表（按时间）
  final Map<String, List<ChatMessage>> _messages = {};

  /// 对端名称缓存：peerId -> name
  final Map<String, String> _peerNames = {};
  final Map<String, DeviceType> _peerTypes = {};

  /// 对端角色与 IP 缓存：设备离线后列表仍要显示它的用途角标和 IP 尾段，
  /// 而 _online 只保留当前在线设备，所以这两个必须像名字一样单独缓存
  final Map<String, DeviceRole> _peerRoles = {};
  final Map<String, String> _peerHosts = {};

  /// 传输任务：taskId -> task
  final Map<String, TransferTask> transfers = {};
  final Map<String, Map<String, dynamic>> _incomingPrintJobs = {};

  /// 当前活动会话对端 id
  String? activePeerId;

  /// 多选群发选中的设备 id
  final Set<String> selected = {};

  /// 会话页当前是否打开着（由聊天视图 initState/dispose 维护）。
  /// 与 [windowVisible] 一起决定"收到消息是否顺手标记已读"。
  bool chatPageOpen = false;

  /// 窗口是否可见（最小化/隐藏到托盘时为 false，由 WindowListener 维护）。
  /// 默认 true：桌面端启动即可见，移动端恒为 true（不做窗口概念）。
  bool windowVisible = true;

  /// UI 提示回调（弹窗/SnackBar）
  void Function(String message)? onNotice;

  /// Windows 原生打印共享（SMB）是否已建立。
  /// 内存态缓存：由打印服务页加载/启用成功后写入，首页状态灯消费，
  /// 避免首页每次都起 PowerShell 查询。真实状态以打印页进入时的查询为准。
  bool smbShared = false;

  bool get loggedIn => identity != null;

  // ---------------- 初始化 ----------------

  Future<void> init() async {
    await storage.init();
    settings = storage.loadSettings();
    settings.saveDir ??= await storage.defaultSaveDir();
    identity = storage.loadIdentity();
    // 载入历史会话名
    for (final peer in storage.historyPeers()) {
      final msgs = storage.loadHistory(peer);
      if (msgs.isNotEmpty) {
        _messages[peer] = msgs;
        final last = msgs.lastWhere((m) => !m.outgoing, orElse: () => msgs.last);
        _peerNames[peer] = last.outgoing ? (_peerNames[peer] ?? '设备') : last.fromName;
      }
    }
    // 从旧版本升级：老配置没有已读水位，不补基线的话一启动就满屏 99+
    final noBaseline =
        _messages.keys.where((id) => !settings.peerLastRead.containsKey(id)).toList();
    if (noBaseline.isNotEmpty) _seedUnreadBaseline(noBaseline);
    if (identity != null && settings.autoOnline) {
      await goOnline();
    }
    // 打印服务独立于登录态：开机进托盘后即可对外可用
    await syncPrintService();
    // 启动时探测一次 SMB 共享状态：首页打印灯据此显示，
    // 否则 smbShared 只在用户进过打印服务页后才被刷新，重启后灯恒灰
    if (Platform.isWindows) {
      try {
        smbShared = await PrintShareService.isShared();
      } catch (_) {}
    }
    notifyListeners();
  }

  // ---------------- 打印服务 ----------------

  Future<void> setPrintEnabled(bool v) async {
    settings.printEnabled = v;
    await storage.saveSettings(settings);
    await syncPrintService();
    notifyListeners();
  }

  Future<void> setPrintToken(String v) async {
    settings.printToken = v;
    await storage.saveSettings(settings);
    await syncPrintService();
    notifyListeners();
  }

  Future<void> setPrintPrinter(String v) async {
    settings.printPrinter = v;
    await storage.saveSettings(settings);
    await syncPrintService();
    notifyListeners();
  }

  Future<void> setPrintDailyPages(int v) async {
    settings.printDailyPages = v;
    await storage.saveSettings(settings);
    await syncPrintService();
    notifyListeners();
  }

  /// 按设置启停 IPP 服务（仅 Windows；其余平台空操作）
  Future<void> syncPrintService() async {
    if (!Platform.isWindows) return;
    final s = settings;
    if (s.printEnabled && s.printPrinter.isNotEmpty) {
      if (s.printToken.isEmpty) {
        settings.printToken = PrintService.instance.newToken();
        await storage.saveSettings(settings);
      }
      await PrintService.instance
          .start(s.printToken, s.printPrinter, dailyQuota: s.printDailyPages);
    } else if (PrintService.instance.running) {
      await PrintService.instance.stop();
    }
  }

  // ---------------- 登录 / 登出 ----------------

  Future<void> loginWithPassword(
      String accountId, String password, String? deviceName) async {
    final deviceId = await DeviceBootstrap.deviceId();
    final name = (deviceName == null || deviceName.trim().isEmpty)
        ? await DeviceBootstrap.defaultName()
        : deviceName.trim();
    identity = Identity(
      accountId: accountId.trim(),
      groupId: Identity.deriveGroupId(accountId, password),
      deviceId: deviceId,
      deviceName: name,
      deviceType: DeviceBootstrap.currentType(),
    );
    await storage.saveIdentity(identity!);
    await goOnline();
    notifyListeners();
  }

  /// 扫码登录：应用手机下发的账号凭证到本设备
  Future<void> applyGrantedIdentity(Identity granted) async {
    final deviceId = await DeviceBootstrap.deviceId();
    final name = await DeviceBootstrap.defaultName();
    identity = Identity(
      accountId: granted.accountId,
      groupId: granted.groupId,
      deviceId: deviceId,
      deviceName: name,
      deviceType: DeviceBootstrap.currentType(),
    );
    await storage.saveIdentity(identity!);
    await goOnline();
    onNotice?.call('扫码登录成功');
    notifyListeners();
  }

  Future<void> logout() async {
    await goOffline();
    await storage.clearIdentity();
    identity = null;
    _messages.clear();
    _peerNames.clear();
    _online.clear();
    selected.clear();
    activePeerId = null;
    notifyListeners();
  }

  // ---------------- 上线 / 下线 ----------------

  TransportCallbacks _callbacks() => TransportCallbacks(
        onDevicesChanged: _onDevicesChanged,
        onText: _onText,
        onImage: _onImage,
        onFileOffer: _onFileOffer,
        onFileProgress: _onFileProgress,
        onFileDone: _onFileDone,
        onFileError: _onFileError,
        onPrintJobOffer: _onPrintJobOffer,
        onLoginGranted: (id) => applyGrantedIdentity(id),
        onAvatarSync: _onPeerAvatar,
      );

  Future<void> goOnline() async {
    if (identity == null || online) return;
    _transport.saveDirectory = settings.saveDir ?? '';
    await _transport.start(identity!, _callbacks());
    online = true;
    notifyListeners();
  }

  Future<void> goOffline() async {
    if (!online) return;
    await _transport.stop();
    online = false;
    _online.clear();
    notifyListeners();
  }

  void refresh() => _transport.refresh();

  /// 删除离线设备：清除聊天记录和本地缓存
  Future<void> deletePeer(String peerId) async {
    await storage.clearHistory(peerId);
    _messages.remove(peerId);
    _peerNames.remove(peerId);
    _peerTypes.remove(peerId);
    _peerRoles.remove(peerId);
    _peerHosts.remove(peerId);
    // 备注名与已读水位一并清除：残留会让以后同 id 设备的未读数算错
    settings.peerAlias.remove(peerId);
    settings.peerLastRead.remove(peerId);
    _invalidateUnread(peerId);
    await storage.saveSettings(settings);
    if (activePeerId == peerId) activePeerId = null;
    selected.remove(peerId);
    notifyListeners();
  }

  // ---------------- 设备列表 ----------------

  void _onDevicesChanged(List<RemoteDevice> devices) {
    _online
      ..clear()
      ..addEntries(devices.map((d) => MapEntry(d.deviceId, d)));
    final fresh = <String>[];
    for (final d in devices) {
      _peerNames[d.deviceId] = d.name;
      _peerTypes[d.deviceId] = d.type;
      if (d.role != DeviceRole.unset) _peerRoles[d.deviceId] = d.role;
      if (d.host.isNotEmpty) _peerHosts[d.deviceId] = d.host;
      if (!settings.peerLastRead.containsKey(d.deviceId)) fresh.add(d.deviceId);
    }
    // 首次见到的设备先打「已读基线」：不加这一步，历史会话里的旧消息
    // 会被整堆算成未读，一上线就是几台机器各 99+，功能直接变成噪音
    if (fresh.isNotEmpty) _seedUnreadBaseline(fresh);
    // 清理不再在线的多选项
    selected.removeWhere((id) => !_online.containsKey(id));
    notifyListeners();
  }

  /// 给一批设备设未读基线为"现在"，并落盘
  Future<void> _seedUnreadBaseline(List<String> ids) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    for (final id in ids) {
      settings.peerLastRead[id] = now;
    }
    _invalidateUnread();
    await storage.saveSettings(settings);
  }

  /// 设备列表视图：在线在前，其次有未读的在前，最后按展示名
  List<PeerView> get peers {
    final now = DateTime.now();
    final map = <String, PeerView>{};
    for (final d in _online.values) {
      map[d.deviceId] = _buildPeerView(d.deviceId, d.name, d.type, d.online,
          role: d.role,
          unreachable: d.unreachable,
          host: d.host,
          now: now);
    }
    for (final id in {..._messages.keys, ..._peerNames.keys}) {
      if (map.containsKey(id)) continue;
      map[id] = _buildPeerView(
        id,
        _peerNames[id] ?? '设备',
        _peerTypes[id] ?? DeviceType.other,
        false,
        role: _peerRoles[id] ?? DeviceRole.unset,
        host: _peerHosts[id],
        now: now,
      );
    }
    final list = map.values.toList();
    list.sort((a, b) {
      if (a.online != b.online) return a.online ? -1 : 1;
      // 有未读的排前面：设备一多，"谁找过我"比字母顺序重要得多
      if ((a.unread > 0) != (b.unread > 0)) return a.unread > 0 ? -1 : 1;
      return a.displayName.compareTo(b.displayName);
    });
    return list;
  }

  /// 组装单个视图：把未读数与最近一条收到的消息从会话表里算出来
  PeerView _buildPeerView(
    String id,
    String name,
    DeviceType type,
    bool online, {
    DeviceRole role = DeviceRole.unset,
    bool unreachable = false,
    String? host,
    required DateTime now,
  }) {
    final msgs = _messages[id] ?? const <ChatMessage>[];
    return PeerView(
      id: id,
      name: name,
      type: type,
      online: online,
      role: role,
      unreachable: unreachable,
      host: host,
      alias: settings.peerAlias[id] ?? '',
      unread: unreadOf(id),
      lastIncoming: lastIncomingMessage(msgs),
    );
  }

  RemoteDevice? deviceById(String id) => _online[id];

  RemoteDevice? onlineDevice(String id) => _online[id];

  // ---------------- 诊断 ----------------

  /// 本机网卡 IPv4 列表（网卡名 + IP/前缀）
  Future<List<String>> localNetInfo() => _transport.localNetInfo();

  /// 本机参与逐网卡广播的网卡数（>1 时诊断页给出多网卡提示）
  int get broadcastNicCount => _transport.broadcastNicCount;

  /// 手动按 IP 直连一台设备（广播不可达时的兜底）。
  /// 返回 null 表示成功；否则为可读失败原因。
  Future<String?> connectManual(String host) =>
      _transport.connectManual(host);

  /// 已发现设备的诊断快照
  List<PeerDiag> peerDiags() => _transport.peerDiags();

  /// 主动探测某台设备 TCP 是否可达；null 表示可达
  Future<String?> probePeer(String did) => _transport.probePeer(did);

  // ---------------- 会话 ----------------

  List<ChatMessage> messagesOf(String peerId) => _messages[peerId] ?? const [];

  void selectPeer(String id) {
    activePeerId = id;
    // 打开会话即视为读完：把水位推到当前，红点随之消失
    markPeerRead(id);
    notifyListeners();
  }

  // ---------------- 未读与设备识别 ----------------

  /// 全部未读条数（任务栏闪烁、窗口标题计数都看这个）
  int get totalUnread {
    var n = 0;
    for (final id in {..._messages.keys, ..._peerNames.keys}) {
      n += unreadOf(id);
    }
    return n;
  }

  /// 某台设备的未读条数：只数「收到方向且晚于已读水位」的消息。
  ///
  /// 刻意从最终消息列表算，而不是收到一条就 +1——重发/对端重传会走
  /// 同 id 覆盖，增量计数会把一条算成两条。
  ///
  /// 结果按设备记忆化：设备列表和 [totalUnread] 会在每次 notifyListeners
  /// 时重算，而传输进度每 100ms 就刷新一次，不缓存等于每 100ms 全量扫
  /// 一遍历史消息——那正是前面几个版本在治的界面卡顿来源。
  int unreadOf(String peerId) => _unreadMemo.putIfAbsent(
      peerId,
      () => countIncomingUnread(_messages[peerId] ?? const [],
          settings.peerLastRead[peerId] ?? 0));

  /// 未读缓存：任何影响消息集合或已读水位的操作都必须失效对应项
  final Map<String, int> _unreadMemo = {};

  void _invalidateUnread([String? peerId]) {
    if (peerId == null) {
      _unreadMemo.clear();
    } else {
      _unreadMemo.remove(peerId);
    }
  }

  /// 把某台设备的已读水位推到当前并落盘
  void markPeerRead(String peerId) {
    settings.peerLastRead[peerId] = DateTime.now().millisecondsSinceEpoch;
    _invalidateUnread(peerId); // 水位变了，缓存的未读数必须重算，否则红点不消
    storage.saveSettings(settings);
  }

  /// 窗口重新回到前台时调用：正开着的那个会话视为已读。
  /// 没有这一步，用户最小化期间攒下的未读，回来后即便一直盯着看也不会消。
  void syncActiveRead() {
    final id = activePeerId;
    if (id == null || !chatPageOpen || !windowVisible) return;
    if (unreadOf(id) == 0) return; // 没有未读就别白写一次磁盘
    markPeerRead(id);
    notifyListeners();
  }

  /// 设置本机备注名（空串=清除）。只写本地设置，绝不回写对方设备。
  Future<void> setPeerAlias(String peerId, String alias) async {
    final v = alias.trim();
    if (v.isEmpty) {
      settings.peerAlias.remove(peerId);
    } else {
      settings.peerAlias[peerId] = v;
    }
    await storage.saveSettings(settings);
    notifyListeners();
  }

  /// 修改本机设备角色（用途标签），落盘后立即重发广播让同组设备更新角标
  Future<void> setDeviceRole(DeviceRole role) async {
    final id = identity;
    if (id == null) return;
    identity = id.copyWith(deviceRole: role);
    await storage.saveIdentity(identity!);
    notifyListeners();
    if (online) _transport.reannounce();
  }

  void toggleSelect(String id) {
    if (selected.contains(id)) {
      selected.remove(id);
    } else {
      selected.add(id);
    }
    notifyListeners();
  }

  /// 发送目标：多选优先，否则当前会话；仅保留真实在线的设备
  List<RemoteDevice> _targets() {
    Iterable<RemoteDevice> src;
    if (selected.isNotEmpty) {
      src = selected.map((id) => _online[id]).whereType<RemoteDevice>();
    } else {
      final a = activePeerId;
      src = (a != null && _online[a] != null)
          ? [_online[a]!]
          : const <RemoteDevice>[];
    }
    return src.where((d) => d.online).toList();
  }

  Future<void> _addMessage(ChatMessage m) async {
    final list = _messages[m.peerId] ??= [];
    // 同 id（失败重发/对端重发）覆盖旧记录，避免重复显示
    final i = m.id.isEmpty ? -1 : list.indexWhere((e) => e.id == m.id);
    if (i >= 0) {
      list[i] = m;
    } else {
      list.add(m);
    }
    // 消息集合变了，未读缓存必须失效（markPeerRead 分支自带失效，
    // 这里兜住"没走那条分支"的绝大多数情况）
    _invalidateUnread(m.peerId);
    // 收到的消息：仅当"这个会话正开着、且窗口确实可见"时顺手标记已读。
    // 必须带上可见性判断——最小化到托盘时若也算已读，未读数永远不增长，
    // 任务栏闪烁就再也不会触发，等于把最需要的场景漏掉了。
    if (!m.outgoing &&
        m.peerId == activePeerId &&
        chatPageOpen &&
        windowVisible) {
      markPeerRead(m.peerId);
    }
    await storage.appendHistory(m);
    notifyListeners();
  }

  Future<void> _updateMessage(ChatMessage m) async {
    final list = _messages[m.peerId];
    if (list == null) return;
    final i = list.indexWhere((e) => e.id == m.id);
    if (i >= 0) list[i] = m;
    _invalidateUnread(m.peerId);
    // 追加覆盖行（读取时按 id 去重取最新），
    // 不再全量重写历史文件——旧方案随记录增长越来越卡
    await storage.appendHistory(m);
    notifyListeners();
  }

  /// 进度回调节流：最多每 100ms 刷新一次界面，避免高频刷新导致卡顿
  void _bumpProgress(TransferTask t, int bytes) {
    t.transferredBytes = bytes;
    final now = DateTime.now();
    if (now.difference(t.updatedAt) < const Duration(milliseconds: 100)) {
      return;
    }
    t.updatedAt = now;
    notifyListeners();
  }

  // ---------------- 发送：文本 ----------------

  Future<void> sendText(String text) async {
    if (text.trim().isEmpty) return;
    final targets = _targets();
    if (targets.isEmpty) {
      onNotice?.call('请先选择在线设备');
      return;
    }
    for (final d in targets) {
      final msg = ChatMessage(
        id: _uuid.v4(),
        peerId: d.deviceId,
        fromId: identity!.deviceId,
        fromName: identity!.deviceName,
        outgoing: true,
        kind: MessageKind.text,
        time: DateTime.now(),
        text: text,
        status: MessageStatus.sending,
      );
      await _addMessage(msg);
      try {
        await _transport.sendText(d, msg.id, text);
        await _updateMessage(msg.copyWith(status: MessageStatus.sent));
      } catch (e) {
        log.e('Send', '文本发送失败: $e');
        await _updateMessage(msg.copyWith(status: MessageStatus.failed));
        _transport.resetPeer(d.deviceId); // 连接疑似卡死，主动重建
      }
    }
  }

  // ---------------- 发送：图片 ----------------

  Future<void> sendImageBytes(Uint8List bytes, {String? name}) async {
    final targets = _targets();
    if (targets.isEmpty) {
      onNotice?.call('请先选择在线设备');
      return;
    }
    final fileName =
        name ?? 'clip_${DateTime.now().millisecondsSinceEpoch}.png';
    for (final d in targets) {
      final msg = ChatMessage(
        id: _uuid.v4(),
        peerId: d.deviceId,
        fromId: identity!.deviceId,
        fromName: identity!.deviceName,
        outgoing: true,
        kind: MessageKind.image,
        time: DateTime.now(),
        fileName: fileName,
        fileSize: bytes.length,
        status: MessageStatus.sending,
      );
      await _addMessage(msg);
      try {
        await _transport.sendImage(d, msg.id, bytes, fileName);
        await _updateMessage(msg.copyWith(status: MessageStatus.sent));
      } catch (e) {
        log.e('Send', '图片发送失败: $e');
        await _updateMessage(msg.copyWith(status: MessageStatus.failed));
        _transport.resetPeer(d.deviceId);
      }
    }
  }

  // ---------------- 发送：文件 ----------------

  Future<void> sendFilePath(String filePath) async {
    final targets = _targets();
    if (targets.isEmpty) {
      onNotice?.call('请先选择在线设备');
      return;
    }
    final file = File(filePath);
    if (!await file.exists()) return;
    final size = await file.length();
    final name = p.basename(filePath);
    for (final d in targets) {
      await _sendOneFile(d, filePath, name, size);
    }
  }

  Future<void> _sendOneFile(
      RemoteDevice d, String filePath, String name, int size) async {
    final msg = ChatMessage(
      id: _uuid.v4(),
      peerId: d.deviceId,
      fromId: identity!.deviceId,
      fromName: identity!.deviceName,
      outgoing: true,
      kind: MessageKind.file,
      time: DateTime.now(),
      localPath: filePath,
      fileName: name,
      fileSize: size,
      status: MessageStatus.sending,
    );
    await _addMessage(msg);
    final taskId = _uuid.v4();
    final task = TransferTask(
      taskId: taskId,
      peerId: d.deviceId,
      fileName: name,
      totalBytes: size,
      outgoing: true,
      path: filePath,
      messageId: msg.id,
      state: TransferState.transferring,
    );
    transfers[taskId] = task;
    notifyListeners();
    try {
      await _transport.sendFile(d, taskId, filePath, name, size,
          onProgress: (sent, total) => _bumpProgress(task, sent));
      task.state = TransferState.completed;
      task.updatedAt = DateTime.now();
      await _updateMessage(msg.copyWith(status: MessageStatus.sent));
    } catch (e) {
      log.e('Send', '文件发送失败: $e');
      task.state = TransferState.failed;
      await _updateMessage(msg.copyWith(status: MessageStatus.failed));
      onNotice?.call('文件发送失败，可点击重发');
      _transport.resetPeer(d.deviceId); // 连接疑似卡死，主动重建
    }
    notifyListeners();
  }

  /// 发送内部打印任务；对端收到后自动调用已配置的本机打印机。
  Future<void> sendPrintJob(RemoteDevice to, String filePath,
      {int copies = 1,
      String pages = '',
      String duplex = '',
      bool color = false,
      int paperCode = 0}) async {
    final file = File(filePath);
    if (!await file.exists()) throw StateError('文件不存在');
    final size = await file.length();
    final taskId = _uuid.v4();
    final task = TransferTask(
      taskId: taskId,
      peerId: to.deviceId,
      fileName: p.basename(filePath),
      totalBytes: size,
      outgoing: true,
      path: filePath,
      messageId: '',
      state: TransferState.transferring,
    );
    transfers[taskId] = task;
    notifyListeners();
    try {
      await _transport.sendPrintJob(to, taskId, filePath, task.fileName,
          size, options: {
            'copies': copies.clamp(1, 99),
            'pages': pages,
            'duplex': duplex,
            'color': color,
            'paperCode': paperCode,
          }, onProgress: (sent, _) => _bumpProgress(task, sent));
      task.state = TransferState.completed;
    } catch (_) {
      task.state = TransferState.failed;
      rethrow;
    } finally {
      notifyListeners();
    }
  }

  /// 失败重发
  Future<void> retryMessage(ChatMessage m) async {
    final d = _online[m.peerId];
    if (d == null || !d.online) {
      onNotice?.call('对方设备不在线');
      return;
    }
    if (m.kind == MessageKind.text) {
      try {
        await _transport.sendText(d, m.id, m.text ?? '');
        await _updateMessage(m.copyWith(status: MessageStatus.sent));
      } catch (_) {
        await _updateMessage(m.copyWith(status: MessageStatus.failed));
      }
    } else if (m.kind == MessageKind.file && m.localPath != null) {
      await _updateMessage(m.copyWith(status: MessageStatus.sending));
      final size = m.fileSize ?? 0;
      final taskId = _uuid.v4();
      final task = TransferTask(
        taskId: taskId,
        peerId: d.deviceId,
        fileName: m.fileName ?? 'file',
        totalBytes: size,
        outgoing: true,
        path: m.localPath!,
        messageId: m.id,
        state: TransferState.transferring,
      );
      transfers[taskId] = task;
      try {
        await _transport.sendFile(
            d, taskId, m.localPath!, m.fileName ?? 'file', size,
            onProgress: (sent, total) => _bumpProgress(task, sent));
        task.state = TransferState.completed;
        await _updateMessage(m.copyWith(status: MessageStatus.sent));
      } catch (_) {
        task.state = TransferState.failed;
        await _updateMessage(m.copyWith(status: MessageStatus.failed));
      }
      notifyListeners();
    }
  }

  // ---------------- 接收 ----------------

  void _touchPeer(RemoteDevice from) {
    _peerNames[from.deviceId] = from.name;
    _peerTypes[from.deviceId] = from.type;
  }

  Future<void> _onText(
      RemoteDevice from, String msgId, String text, DateTime ts) async {
    _touchPeer(from);
    await _addMessage(ChatMessage(
      id: msgId.isEmpty ? _uuid.v4() : msgId,
      peerId: from.deviceId,
      fromId: from.deviceId,
      fromName: from.name,
      outgoing: false,
      kind: MessageKind.text,
      time: ts,
      text: text,
      status: MessageStatus.received,
    ));
    _notifyIncoming(from, '发来一条消息');
  }

  Future<void> _onImage(RemoteDevice from, String msgId, String savePath,
      String name) async {
    _touchPeer(from);
    // 安卓：把图片从缓存发布到公共相册目录（零权限），
    // 这样相册和任何文件管理器都能看到，"打开所在位置"也必然可用
    var path = savePath;
    var where = '';
    if (AndroidPublicStore.supported && settings.autoSavePublic) {
      final pf = await AndroidPublicStore.publish(savePath, name, image: true);
      if (pf != null) {
        path = pf.path;
        where = ' · 已存 ${pf.friendlyDir}';
      }
    }
    await _addMessage(ChatMessage(
      id: msgId.isEmpty ? _uuid.v4() : msgId,
      peerId: from.deviceId,
      fromId: from.deviceId,
      fromName: from.name,
      outgoing: false,
      kind: MessageKind.image,
      time: DateTime.now(),
      localPath: path,
      fileName: name,
      status: MessageStatus.received,
    ));
    _notifyIncoming(from, '发来一张图片$where');
  }

  void _onFileOffer(
      RemoteDevice from, String taskId, String name, int size) {
    _touchPeer(from);
    transfers[taskId] = TransferTask(
      taskId: taskId,
      peerId: from.deviceId,
      fileName: name,
      totalBytes: size,
      outgoing: false,
      path: '',
      messageId: '',
      state: TransferState.transferring,
    );
    notifyListeners();
  }

  void _onPrintJobOffer(RemoteDevice from, String taskId, String name, int size,
      Map<String, dynamic> options) {
    _touchPeer(from);
    _incomingPrintJobs[taskId] = options;
    transfers[taskId] = TransferTask(
      taskId: taskId,
      peerId: from.deviceId,
      fileName: name,
      totalBytes: size,
      outgoing: false,
      path: '',
      messageId: '',
      state: TransferState.transferring,
    );
    onNotice?.call('${from.name} 发来打印任务，接收后自动打印');
    notifyListeners();
  }

  void _onFileProgress(String taskId, int received, int total) {
    final t = transfers[taskId];
    if (t == null) return;
    _bumpProgress(t, received);
  }

  Future<void> _onFileDone(String taskId, String savePath) async {
    final t = transfers[taskId];
    if (t == null) return;
    final printOptions = _incomingPrintJobs.remove(taskId);
    if (printOptions != null) {
      t.state = TransferState.completed;
      t.transferredBytes = t.totalBytes;
      final printer = settings.printPrinter;
      if (!PrintEngine.supported || printer.isEmpty) {
        onNotice?.call('未配置可用打印机，打印任务未输出');
        return;
      }
      try {
        await PrintEngine.instance.ensureHandler();
        final accepted = await PrintEngine.instance.printPdf(
          path: savePath,
          printer: printer,
          jobId: DateTime.now().millisecondsSinceEpoch,
          copies: (printOptions['copies'] as int?) ?? 1,
          pages: printOptions['pages'] as String? ?? '',
          duplex: printOptions['duplex'] as String? ?? '',
          color: printOptions['color'] as bool? ?? false,
          paperCode: (printOptions['paperCode'] as int?) ?? 0,
        );
        if (!accepted) onNotice?.call('打印任务未能提交');
      } catch (e) {
        onNotice?.call('自动打印失败：$e');
      }
      return;
    }
    t.state = TransferState.completed;
    t.transferredBytes = t.totalBytes;
    // 安卓：把文件从应用目录发布到公共「下载/CrossLink」（零权限），
    // 文件管理器可直接看到，"打开所在位置"必然可用
    var path = savePath;
    var where = '';
    if (AndroidPublicStore.supported && settings.autoSavePublic) {
      final pf =
          await AndroidPublicStore.publish(savePath, t.fileName, image: false);
      if (pf != null) {
        path = pf.path;
        where = ' · 已存 ${pf.friendlyDir}';
      }
    }
    await _addMessage(ChatMessage(
      id: _uuid.v4(),
      peerId: t.peerId,
      fromId: t.peerId,
      fromName: _peerNames[t.peerId] ?? '设备',
      outgoing: false,
      kind: MessageKind.file,
      time: DateTime.now(),
      localPath: path,
      fileName: t.fileName,
      fileSize: t.totalBytes,
      status: MessageStatus.received,
    ));
    final d = _online[t.peerId];
    if (d != null) _notifyIncoming(d, '发来一个文件$where');
    notifyListeners();
  }

  void _onFileError(String taskId, String reason) {
    final t = transfers[taskId];
    if (t != null) t.state = TransferState.failed;
    onNotice?.call('文件接收失败：$reason');
    notifyListeners();
  }

  void _notifyIncoming(RemoteDevice from, String what) {
    if (settings.notifyOnReceive) {
      onNotice?.call('${from.name} $what');
    }
  }

  // ---------------- 设置 ----------------

  Future<void> setDeviceName(String name) async {
    if (identity == null || name.trim().isEmpty) return;
    identity = identity!.copyWith(deviceName: name.trim());
    await storage.saveIdentity(identity!);
    // 重新上线以广播新名字
    if (online) {
      await goOffline();
      await goOnline();
    }
    notifyListeners();
  }

  Future<void> setSaveDir(String dir) async {
    settings.saveDir = dir;
    _transport.saveDirectory = dir;
    await storage.saveSettings(settings);
    notifyListeners();
  }

  /// 恢复系统默认保存目录（安卓即应用私有目录）
  Future<void> useDefaultSaveDir() async {
    final d = await storage.defaultSaveDir();
    await setSaveDir(d);
  }

  /// 安卓：是否自动把收到的文件/图片发布到公共目录（零权限）
  Future<void> setAutoSavePublic(bool v) async {
    settings.autoSavePublic = v;
    await storage.saveSettings(settings);
    notifyListeners();
  }

  Future<void> setNotify(bool v) async {
    settings.notifyOnReceive = v;
    await storage.saveSettings(settings);
    notifyListeners();
  }

  Future<void> setAutoOnline(bool v) async {
    settings.autoOnline = v;
    await storage.saveSettings(settings);
    notifyListeners();
  }

  Future<void> setEnterToSend(bool v) async {
    settings.enterToSend = v;
    await storage.saveSettings(settings);
    notifyListeners();
  }

  Future<void> setImagePreview(bool v) async {
    settings.imagePreview = v;
    await storage.saveSettings(settings);
    notifyListeners();
  }

  /// 截图时是否隐藏本窗口（截自身截图反馈问题时关闭）
  Future<void> setScreenshotHideWindow(bool v) async {
    settings.screenshotHideWindow = v;
    await storage.saveSettings(settings);
    notifyListeners();
  }

  Future<void> setScreenshotHotkey(String? json) async {
    settings.screenshotHotkey = json;
    await storage.saveSettings(settings);
    notifyListeners();
  }

  /// 桌面端：点 × 的行为（'tray' / 'ask' / 'quit'）
  Future<void> setCloseBehavior(String v) async {
    settings.closeBehavior = v;
    await storage.saveSettings(settings);
    notifyListeners();
  }

  /// 桌面端：开机自动启动
  Future<void> setAutoStart(bool v) async {
    settings.autoStart = v;
    await storage.saveSettings(settings);
    notifyListeners();
  }

  /// 安卓后台保活开关（实际前台服务启停由 UI 层调用 BackgroundKeepAlive）
  Future<void> setBackgroundOnline(bool v) async {
    settings.backgroundOnline = v;
    await storage.saveSettings(settings);
    notifyListeners();
  }

  /// 主题换色（null 恢复默认 QQ 蓝）
  Future<void> setThemeColor(int? v) async {
    settings.themeColor = v;
    await storage.saveSettings(settings);
    notifyListeners();
  }

  /// 设置/更新头像（传入选中的源图片路径，内部复制到应用目录）
  /// 保存后立即向已连接设备同步（另一端跟着变）
  Future<void> setAvatar(String srcPath) async {
    if (identity == null) return;
    final saved = await storage.saveAvatar(srcPath);
    identity = identity!.copyWith(avatarPath: saved);
    await storage.saveIdentity(identity!);
    notifyListeners();
    if (online) await _transport.syncAvatar();
  }

  /// 收到对端同步来的头像：比本机头像新才采用（较新者胜出，防回声循环）
  Future<void> _onPeerAvatar(Uint8List bytes, int ts) async {
    if (identity == null || ts <= 0) return;
    final mineTs = _transport.avatarTimestamp(identity!.avatarPath);
    if (ts <= mineTs) return; // 对方不比我新（相同时间戳也不重复采用）
    try {
      final saved = await storage.saveAvatarBytes(bytes, ts);
      identity = identity!.copyWith(avatarPath: saved);
      await storage.saveIdentity(identity!);
      log.i('Sync', '已从对端同步头像');
      notifyListeners();
    } catch (e) {
      log.w('Sync', '保存对端头像失败: $e');
    }
  }

  Future<void> clearConversation(String peerId) async {
    _messages.remove(peerId);
    _invalidateUnread(peerId); // 消息清空后红点必须跟着消失
    await storage.clearHistory(peerId);
    notifyListeners();
  }

  // ---------------- 扫码登录 ----------------

  Future<Map<String, dynamic>> startLoginBeacon() =>
      _transport.startLoginBeacon((granted) => applyGrantedIdentity(granted));

  Future<void> grantLoginTo(String host, int port) async {
    if (identity == null) return;
    await _transport.grantLogin(host, port, identity!);
    onNotice?.call('已向对方设备下发登录凭证');
  }
}
