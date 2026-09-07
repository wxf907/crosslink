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
import '../services/storage_service.dart';

/// 设备在列表中的展示视图（合并在线设备 + 历史会话）
class PeerView {
  final String id;
  final String name;
  final DeviceType type;
  final bool online;

  /// 能收到对方广播但 TCP 连不上（多半是对方防火墙未放行）
  final bool unreachable;
  PeerView(this.id, this.name, this.type, this.online,
      [this.unreachable = false]);
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

  /// 传输任务：taskId -> task
  final Map<String, TransferTask> transfers = {};

  /// 当前活动会话对端 id
  String? activePeerId;

  /// 多选群发选中的设备 id
  final Set<String> selected = {};

  /// UI 提示回调（弹窗/SnackBar）
  void Function(String message)? onNotice;

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
    if (identity != null && settings.autoOnline) {
      await goOnline();
    }
    notifyListeners();
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
    if (activePeerId == peerId) activePeerId = null;
    selected.remove(peerId);
    notifyListeners();
  }

  // ---------------- 设备列表 ----------------

  void _onDevicesChanged(List<RemoteDevice> devices) {
    _online
      ..clear()
      ..addEntries(devices.map((d) => MapEntry(d.deviceId, d)));
    for (final d in devices) {
      _peerNames[d.deviceId] = d.name;
      _peerTypes[d.deviceId] = d.type;
    }
    // 清理不再在线的多选项
    selected.removeWhere((id) => !_online.containsKey(id));
    notifyListeners();
  }

  /// 设备列表视图：在线设备在前，历史离线设备在后
  List<PeerView> get peers {
    final map = <String, PeerView>{};
    for (final d in _online.values) {
      map[d.deviceId] =
          PeerView(d.deviceId, d.name, d.type, d.online, d.unreachable);
    }
    for (final id in {..._messages.keys, ..._peerNames.keys}) {
      if (map.containsKey(id)) continue;
      map[id] = PeerView(id, _peerNames[id] ?? '设备',
          _peerTypes[id] ?? DeviceType.other, false);
    }
    final list = map.values.toList();
    list.sort((a, b) {
      if (a.online != b.online) return a.online ? -1 : 1;
      return a.name.compareTo(b.name);
    });
    return list;
  }

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
    notifyListeners();
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
    await storage.appendHistory(m);
    notifyListeners();
  }

  Future<void> _updateMessage(ChatMessage m) async {
    final list = _messages[m.peerId];
    if (list == null) return;
    final i = list.indexWhere((e) => e.id == m.id);
    if (i >= 0) list[i] = m;
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
    }
    notifyListeners();
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

  void _onFileProgress(String taskId, int received, int total) {
    final t = transfers[taskId];
    if (t == null) return;
    _bumpProgress(t, received);
  }

  Future<void> _onFileDone(String taskId, String savePath) async {
    final t = transfers[taskId];
    if (t == null) return;
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
