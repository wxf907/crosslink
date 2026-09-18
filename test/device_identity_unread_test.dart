import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:crosslink/core/constants.dart';
import 'package:crosslink/models/app_settings.dart';
import 'package:crosslink/models/identity.dart';
import 'package:crosslink/models/message.dart';
import 'package:crosslink/state/app_state.dart';

/// 设备识别（角色/备注名/设备色/IP 尾段）与未读统计的回归测试。
///
/// 这一批逻辑刻意都做成纯函数/纯模型，不碰 StorageService 与平台插件，
/// 因此可以直接跑——未读算错和设备色漂移都是用户一眼就能看见的错误。
ChatMessage _msg({
  required bool outgoing,
  required DateTime time,
  MessageKind kind = MessageKind.text,
  String id = '',
}) =>
    ChatMessage(
      id: id,
      peerId: 'peer',
      fromId: outgoing ? 'me' : 'peer',
      fromName: 'n',
      outgoing: outgoing,
      kind: kind,
      time: time,
    );

PeerView _peer({
  String id = 'cl-w-abc',
  String name = '个人电脑',
  String alias = '',
  DeviceType type = DeviceType.windows,
  DeviceRole role = DeviceRole.unset,
  bool online = true,
  String? host,
}) =>
    PeerView(
      id: id,
      name: name,
      type: type,
      online: online,
      role: role,
      alias: alias,
      host: host,
    );

void main() {
  group('未读统计', () {
    final base = DateTime(2026, 9, 18, 10);

    ChatMessage at(int seconds) =>
        _msg(outgoing: false, time: base.add(Duration(seconds: seconds)));

    test('只数收到方向，且严格晚于已读水位', () {
      final msgs = [
        at(0),
        _msg(outgoing: true, time: at(100).time), // 发出的不算
        at(200),
        at(300),
      ];
      // 水位正好压在 at(0) 上 → 那条算已读，只剩 200/300 两条
      expect(countIncomingUnread(msgs, at(0).time.millisecondsSinceEpoch), 2);
      // 水位早于全部消息 → 3 条收到的全算未读
      expect(
          countIncomingUnread(
              msgs, at(0).time.millisecondsSinceEpoch - 1000),
          3);
    });

    test('水位等于该条时间戳视为已读（避免点开又亮回去）', () {
      final m = at(50);
      expect(
          countIncomingUnread([m], m.time.millisecondsSinceEpoch), 0,
          reason: '边界应为已读');
      expect(
          countIncomingUnread([m], m.time.millisecondsSinceEpoch - 1), 1,
          reason: '水位早 1ms 才算未读');
    });

    test('空会话与全为发出的会话未读为 0', () {
      expect(countIncomingUnread(const [], 0), 0);
      expect(
          countIncomingUnread(
              [_msg(outgoing: true, time: base)], 0),
          0);
    });

    test('预览取最后一条收到的消息，忽略发出的', () {
      final first = at(1);
      final second = at(2);
      final out = _msg(outgoing: true, time: at(3).time);
      expect(lastIncomingMessage([first, out, second]), same(second));
      expect(lastIncomingMessage([out]), isNull);
    });
  });

  group('设置持久化与旧版本升级', () {
    test('老配置没有 peerAlias/peerLastRead 时回退为空表，且可写', () {
      final s = AppSettings.fromJson(const {'saveDir': 'D:/x'});
      expect(s.peerAlias, isEmpty);
      expect(s.peerLastRead, isEmpty);
      // 必须是可写表：给成 const 空表会让后续写入直接抛异常
      expect(() => s.peerAlias['a'] = 'b', returnsNormally);
      expect(() => s.peerLastRead['a'] = 1, returnsNormally);
    });

    test('经 JSON 往返后仍是强类型 Map（动态 Map 必须逐项转换）', () {
      final s = AppSettings()
        ..peerAlias['p1'] = '财务机'
        ..peerLastRead['p1'] = 123;
      final decoded =
          AppSettings.fromJson(jsonDecode(jsonEncode(s.toJson())));
      expect(decoded.peerAlias, isA<Map<String, String>>());
      expect(decoded.peerLastRead, isA<Map<String, int>>());
      expect(decoded.peerAlias['p1'], '财务机');
      expect(decoded.peerLastRead['p1'], 123);
    });
  });

  group('设备角色', () {
    test('未知/缺失字符串一律回退 unset（兼容旧版本对端）', () {
      expect(DeviceRole.fromString(null), DeviceRole.unset);
      expect(DeviceRole.fromString('spaceship'), DeviceRole.unset);
      expect(DeviceRole.fromString('host'), DeviceRole.host);
    });

    test('Identity 带 role 往返；老身份文件缺 role 不炸', () {
      final id = Identity(
        accountId: 'a',
        groupId: 'g',
        deviceId: 'd',
        deviceName: 'n',
        deviceType: DeviceType.windows,
        deviceRole: DeviceRole.host,
      );
      expect(Identity.fromJson(id.toJson()).deviceRole, DeviceRole.host);

      final legacy = Map<String, dynamic>.from(id.toJson())
        ..remove('deviceRole');
      expect(Identity.fromJson(legacy).deviceRole, DeviceRole.unset);
    });
  });

  group('设备识别派生信息', () {
    test('展示名：本地备注优先于对方自报名', () {
      expect(_peer(name: 'gjw', alias: '财务小王').displayName, '财务小王');
      expect(_peer(name: 'gjw').displayName, 'gjw');
    });

    test('设备色：同一 id 恒定，不同 id 不撞色（至少同账号 5 台不重复）', () {
      final ids = [
        'cl-w-1111', 'cl-w-2222', 'cl-w-3333', 'cl-a-4444', 'cl-a-5555',
      ];
      final seeds = ids.map((i) => _peer(id: i).colorSeed).toList();
      expect(_peer(id: 'cl-w-1111').colorSeed, seeds.first,
          reason: '同 id 必须同色，否则跨端显示会打架');
      expect(seeds.toSet().length, ids.length,
          reason: '常见设备 id 之间不应撞色');
      // 种子要能安全取模进调色板（非负）
      for (final s in seeds) {
        expect(s, greaterThanOrEqualTo(0));
      }
    });

    test('首字：中文取汉字、英文取大写字母、备注名优先、空名兜底', () {
      expect(_peer(name: '个人电脑').initial, '个');
      expect(_peer(name: 'gjw').initial, 'G');
      expect(_peer(name: 'gjw', alias: '财务机').initial, '财');
      expect(_peer(name: '   ').initial, '?');
    });

    test('IP 尾段：正常取末段，缺失/异常安全返回', () {
      expect(_peer(host: '192.168.1.23').ipTail, '.23');
      expect(_peer(host: '').ipTail, '');
      expect(_peer(host: null).ipTail, '');
      expect(_peer(host: 'fe80').ipTail, 'fe80');
    });

    test('最近动态：按时间粒度与消息类型措辞，无消息时为空', () {
      final now = DateTime(2026, 9, 18, 12);
      PeerView withMsg(MessageKind kind, Duration ago) => PeerView(
            id: 'p',
            name: 'n',
            type: DeviceType.windows,
            online: true,
            lastIncoming: _msg(outgoing: false, time: now.subtract(ago), kind: kind),
          );

      expect(withMsg(MessageKind.file, const Duration(seconds: 20)).activityLabel(now),
          contains('刚刚'));
      expect(withMsg(MessageKind.file, const Duration(seconds: 20)).activityLabel(now),
          contains('发来文件'));
      expect(withMsg(MessageKind.image, const Duration(minutes: 5)).activityLabel(now),
          '5分钟前 · 发来图片');
      expect(withMsg(MessageKind.text, const Duration(hours: 3)).activityLabel(now),
          '3小时前 · 发来消息');
      expect(withMsg(MessageKind.text, const Duration(days: 2)).activityLabel(now),
          '2天前 · 发来消息');
      expect(_peer().activityLabel(now), '', reason: '没有消息就不该编造动态');
    });
  });
}
