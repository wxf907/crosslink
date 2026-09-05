import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:crosslink/core/constants.dart';
import 'package:crosslink/models/identity.dart';
import 'package:crosslink/net/lan_transport.dart';
import 'package:crosslink/net/transport.dart';

/// 局域网传输端到端集成测试：
/// 同进程启动两个 LanTransport 实例（同 groupId、不同 deviceId），
/// 验证 UDP 互相发现、TCP 文本收发、文件传输全链路。
void main() {
  test('两实例互相发现并收发文本与文件', () async {
    final gid = Identity.deriveGroupId('it-test', 'pw');

    Identity mkId(String did, String name) => Identity(
          accountId: 'it-test',
          groupId: gid,
          deviceId: did,
          deviceName: name,
          deviceType: DeviceType.windows,
        );

    final a = LanTransport();
    final b = LanTransport();

    final tmp = await Directory.systemTemp.createTemp('crosslink_it_');
    a.saveDirectory = tmp.path;
    b.saveDirectory = tmp.path;

    final aSeesBOnline = Completer<RemoteDevice>();
    final bGotText = Completer<String>();
    final bGotFile = Completer<String>();
    final bGone = Completer<void>();

    TransportCallbacks cbs({
      void Function(List<RemoteDevice>)? onDevices,
      void Function(RemoteDevice, String, String, DateTime)? onText,
      void Function(String, String)? onFileDone,
    }) =>
        TransportCallbacks(
          onDevicesChanged: onDevices ?? (_) {},
          onText: onText ?? (_, _, _, _) {},
          onImage: (_, _, _, _) {},
          onFileOffer: (_, _, _, _) {},
          onFileProgress: (_, _, _) {},
          onFileDone: onFileDone ?? (_, _) {},
          onFileError: (_, _) {},
          onLoginGranted: (_) {},
        );

    await a.start(
      mkId('dev-a', 'A机'),
      cbs(onDevices: (list) {
        for (final d in list) {
          if (d.deviceId == 'dev-b' && d.online && !aSeesBOnline.isCompleted) {
            aSeesBOnline.complete(d);
          }
        }
        if (aSeesBOnline.isCompleted &&
            !bGone.isCompleted &&
            !list.any((d) => d.deviceId == 'dev-b')) {
          bGone.complete();
        }
      }),
    );
    await b.start(
      mkId('dev-b', 'B机'),
      cbs(
        onText: (from, id, text, ts) {
          if (!bGotText.isCompleted) bGotText.complete(text);
        },
        onFileDone: (taskId, path) {
          if (!bGotFile.isCompleted) bGotFile.complete(path);
        },
      ),
    );

    // 1. 发现并建立持久连接（在线 = 连接真实可达）
    final devB = await aSeesBOnline.future.timeout(const Duration(seconds: 15));
    expect(devB.deviceId, 'dev-b');
    expect(devB.version, AppConst.protocolVersion);

    // 2. 文本
    await a.sendText(devB, 'msg-1', '你好，B机');
    final text = await bGotText.future.timeout(const Duration(seconds: 10));
    expect(text, '你好，B机');

    // 3. 文件（256KB 随机内容，验证分块传输）
    final src = File('${tmp.path}${Platform.pathSeparator}src.bin');
    final data = List<int>.generate(256 * 1024, (i) => i % 251);
    await src.writeAsBytes(data);
    var lastSent = 0;
    await a.sendFile(devB, 'task-1', src.path, 'recv.bin', data.length,
        onProgress: (sent, total) => lastSent = sent);
    final savedPath = await bGotFile.future.timeout(const Duration(seconds: 15));
    expect(lastSent, data.length);
    final saved = await File(savedPath).readAsBytes();
    expect(saved.length, data.length);
    expect(saved, equals(data));

    // 4. 对端退出后及时消失（不残留“假在线”）
    await b.stop();
    await bGone.future.timeout(const Duration(seconds: 15));

    await a.stop();
    await tmp.delete(recursive: true);
  }, timeout: const Timeout(Duration(seconds: 60)));
}
