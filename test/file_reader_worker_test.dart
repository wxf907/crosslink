import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:crosslink/net/file_reader_worker.dart';

/// 文件读取 worker 单测：
/// 1) 大文件分块读取，块序正确、字节级还原
/// 2) 不足一块的小文件
/// 3) 不存在的文件走 onError
void main() {
  test('worker 分块读取 5MB 文件：块序正确、字节还原、进度回调', () async {
    final tmp = await Directory.systemTemp.createTemp('cl_worker_test');
    final f = File('${tmp.path}${Platform.pathSeparator}big.bin');
    // 5MB + 123 字节（故意非整块，验证尾块）
    const total = 5 * 1024 * 1024 + 123;
    final data = Uint8List.fromList(
        List<int>.generate(total, (i) => (i * 7 + 13) % 256));
    await f.writeAsBytes(data);

    final chunks = <Uint8List>[];
    var doneTotal = -1;
    var lastOffset = -1;
    var offsetMonotonic = true;

    await spawnFileReader(
      path: f.path,
      size: total,
      chunkSize: 256 * 1024,
      onChunk: (chunk, offset) {
        chunks.add(chunk);
        if (offset <= lastOffset) offsetMonotonic = false;
        lastOffset = offset;
      },
      onDone: (t) => doneTotal = t,
      onError: (e) => fail('不应出错: $e'),
    );

    expect(offsetMonotonic, isTrue, reason: 'offset 必须单调递增（块序）');
    expect(doneTotal, total, reason: 'done 回调应报告总字节数');
    // 字节级还原
    var rebuilt = BytesBuilder();
    for (final c in chunks) {
      rebuilt.add(c);
    }
    expect(rebuilt.toBytes(), equals(data), reason: '分块重组后应与原文件一致');
    // V2.6.3：worker 按 4MB 聚合批发（5MB+123B 文件 → 2 批），
    // 消息条数从 21 降到 2，降低主线程消息处理密度
    expect(chunks.length, 2,
        reason: '应按 4MB 聚合批发（4MB+1MB 两批）');

    await tmp.delete(recursive: true);
  }, timeout: const Timeout(Duration(seconds: 60)));

  test('worker 小文件（单块）', () async {
    final tmp = await Directory.systemTemp.createTemp('cl_worker_small');
    final f = File('${tmp.path}${Platform.pathSeparator}small.bin');
    final data = Uint8List.fromList(List<int>.generate(1000, (i) => i % 256));
    await f.writeAsBytes(data);

    var got = 0;
    var doneTotal = -1;
    await spawnFileReader(
      path: f.path,
      size: 1000,
      chunkSize: 256 * 1024,
      onChunk: (c, o) => got += c.length,
      onDone: (t) => doneTotal = t,
      onError: (e) => fail('不应出错: $e'),
    );
    expect(got, 1000);
    expect(doneTotal, 1000);
    await tmp.delete(recursive: true);
  }, timeout: const Timeout(Duration(seconds: 60)));

  test('worker 不存在的文件走 onError', () async {
    var erred = false;
    var doneCalled = false;
    await spawnFileReader(
      path: 'Z:/definitely/not/exist/file.bin',
      size: 100,
      chunkSize: 256 * 1024,
      onChunk: (_, _) {},
      onDone: (_) => doneCalled = true,
      onError: (e) => erred = true,
    );
    expect(erred, isTrue, reason: '读失败必须回调 onError');
    expect(doneCalled, isFalse);
  }, timeout: const Timeout(Duration(seconds: 60)));
}
