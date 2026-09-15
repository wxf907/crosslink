import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:crosslink/core/constants.dart';
import 'package:crosslink/models/identity.dart';
import 'package:crosslink/net/lan_transport.dart';
import 'package:crosslink/net/transport.dart';

/// 大文件传输回归测试：复现用户实测场景
/// （2.6.0 电脑发 14/26MB 安装包到旧版接收端失败）。
/// 15MB 足以触发 worker 读盘与 socket 发送的速度差（背压问题）。
void main() {
  test('15MB 文件传输：worker 读盘路径 + 长连接复用', () async {
    final gid = Identity.deriveGroupId('big-regress', 'pw');

    Identity mkId(String did, String name) => Identity(
          accountId: 'big-regress',
          groupId: gid,
          deviceId: did,
          deviceName: name,
          deviceType: DeviceType.windows,
        );

    final a = LanTransport();
    final b = LanTransport();

    final tmp = await Directory.systemTemp.createTemp('cl_big_test');
    a.saveDirectory = tmp.path;
    b.saveDirectory = tmp.path;

    final aSeesB = Completer<RemoteDevice>();
    final bGotFile = Completer<String>();

    TransportCallbacks cbs({
      void Function(List<RemoteDevice>)? onDevices,
      void Function(String, String)? onFileDone,
    }) =>
        TransportCallbacks(
          onDevicesChanged: onDevices ?? (_) {},
          onText: (_, _, _, _) {},
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
          if (d.deviceId == 'dev-b' && !aSeesB.isCompleted) {
            aSeesB.complete(d);
          }
        }
      }),
    );
    await b.start(
      mkId('dev-b', 'B机'),
      cbs(
        onFileDone: (taskId, path) {
          if (!bGotFile.isCompleted) bGotFile.complete(path);
        },
      ),
    );

    final devB = await aSeesB.future.timeout(const Duration(seconds: 15));

    // 15MB 随机内容（触发 worker 高速读盘 vs socket 发送速度差）
    final src = File('${tmp.path}${Platform.pathSeparator}big.bin');
    const total = 15 * 1024 * 1024;
    final chunk = List<int>.generate(64 * 1024, (i) => (i * 31 + 7) % 256);
    final sink = src.openWrite();
    var written = 0;
    while (written < total) {
      sink.add(chunk);
      written += chunk.length;
    }
    await sink.flush();
    await sink.close();

    var lastSent = 0;
    final sw = Stopwatch()..start();

    // 主线程响应性监测（V2.6.2）：传输期间每 50ms 打点，
    // 任何一次打点延迟 > 2s 判为 UI 卡顿（97% 卡住问题的自动化断言）
    final latencySamples = <int>[];
    Timer? probe;
    var lastTick = DateTime.now();
    probe = Timer.periodic(const Duration(milliseconds: 50), (_) {
      final now = DateTime.now();
      latencySamples.add(now.difference(lastTick).inMilliseconds);
      lastTick = now;
    });

    final sendFuture = a.sendFile(devB, 'task-big', src.path, 'big.bin', total,
        onProgress: (sent, tot) => lastSent = sent);
    final path =
        await bGotFile.future.timeout(const Duration(seconds: 60));
    await sendFuture;
    probe.cancel();
    sw.stop();

    final maxLatency = latencySamples.isEmpty
        ? 0
        : latencySamples.reduce((x, y) => x > y ? x : y);
    // CI 调度抖动容忍 2s；实际 UI 卡顿（尾段积压）表现为持续数百 ms~秒级
    expect(maxLatency, lessThan(2000),
        reason: '传输期间主线程打点最大延迟 ${maxLatency}ms（UI 卡顿回归）');
    // ignore: avoid_print
    print('15MB 传输耗时 ${sw.elapsed}，末次进度 $lastSent，'
        '打点 ${latencySamples.length} 次最大延迟 ${maxLatency}ms');

    final saved = await File(path).readAsBytes();
    expect(saved.length, total, reason: '大小必须一致');
    expect(lastSent, total, reason: '进度必须走满');
    // 源文件逐段比对（全量 equals 对 15MB 也可，这里保守抽查头尾中段）
    final orig = await src.readAsBytes();
    for (final probe in [0, total ~/ 2, total - 65536]) {
      expect(
        saved.sublist(probe, probe + 1024),
        equals(orig.sublist(probe, probe + 1024)),
        reason: '偏移 $probe 处内容不一致（分块错乱）',
      );
    }

    await a.stop();
    await b.stop();
    await tmp.delete(recursive: true);
  }, timeout: const Timeout(Duration(seconds: 120)));
}
