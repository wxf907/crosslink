import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

/// 文件读取 worker：把磁盘读取从 UI 主线程挪走（大文件传输卡界面的主因）。
///
/// V2.6.3 关键改进：
/// - 跨 isolate 传输用 [TransferableTypedData]（零拷贝移交给主线程），
///   消除 V2.6.2 在快网上"一秒冲100%后主线程卡5秒"的问题——
///   根因是 SendPort 直接发 Uint8List 会整块内存拷贝，1200 个小块的
///   拷贝+帧编码全在主线程事件循环里密集执行。
/// - worker 侧聚合成 4MB 大批再发（消息数从千级降到百级），
///   主线程每条消息的处理成本摊薄。
///
/// 协议（worker → 主线程）：
///   {type:'chunk', offset, data: TransferableTypedData}
///   {type:'done', total}
///   {type:'error', error}
Future<void> spawnFileReader({
  required String path,
  required int size,
  required int chunkSize,
  required void Function(Uint8List chunk, int offset) onChunk,
  required void Function(int total) onDone,
  required void Function(Object error) onError,
}) async {
  final ready = ReceivePort();
  final done = Completer<void>();
  final sub = <StreamSubscription>[];

  // 超时保护：worker 崩溃且未发 error 时放行（size 越大时限越宽）
  final watchdog = Timer(
    Duration(seconds: 30 + size ~/ (200 * 1024)),
    () {
      if (!done.isCompleted) done.complete();
    },
  );

  await Isolate.spawn(
    _readerEntry,
    _ReaderArgs(
      path: path,
      size: size,
      chunkSize: chunkSize,
      sendPort: ready.sendPort,
    ),
    errorsAreFatal: true,
  );

  sub.add(ready.listen((msg) {
    if (msg is SendPort) return; // 预留双向通道（当前单向未用）
    if (msg is! Map) return;
    switch (msg['type']) {
      case 'chunk':
        // TransferableTypedData.materialize() 把所有权移入本 isolate，
        // 不发生内容拷贝（这是本版本的核心）
        final ttd = msg['data'] as TransferableTypedData;
        onChunk(ttd.materialize().asUint8List(), msg['offset'] as int);
        break;
      case 'done':
        onDone(msg['total'] as int);
        if (!done.isCompleted) done.complete();
        break;
      case 'error':
        onError(msg['error'] as Object);
        if (!done.isCompleted) done.complete();
        break;
    }
  }, onError: (Object e) {
    onError(e);
    if (!done.isCompleted) done.complete();
  }));

  try {
    await done.future;
  } finally {
    watchdog.cancel();
    for (final s in sub) {
      s.cancel();
    }
    ready.close();
  }
}

void _readerEntry(_ReaderArgs args) async {
  final out = args.sendPort;
  try {
    final raf = File(args.path).openSync();
    try {
      var offset = 0;
      // worker 侧聚合批：4MB 一批发给主线程（减少消息条数）
      const batchTarget = 4 * 1024 * 1024;
      var batch = BytesBuilder(copy: false);
      var batchStart = 0;
      var batchLen = 0;
      while (offset < args.size) {
        final n = (args.size - offset) < args.chunkSize
            ? (args.size - offset)
            : args.chunkSize;
        final chunk = raf.readSync(n);
        if (chunk.isEmpty) break;
        if (batchLen == 0) batchStart = offset;
        batch.add(chunk);
        batchLen += chunk.length;
        offset += chunk.length;
        if (batchLen >= batchTarget || offset >= args.size) {
          final bytes = batch.takeBytes();
          out.send({
            'type': 'chunk',
            'offset': batchStart,
            'data': TransferableTypedData.fromList([bytes]),
          });
          batchLen = 0;
        }
      }
    } finally {
      raf.closeSync();
    }
    out.send({'type': 'done', 'total': args.size});
  } catch (e) {
    out.send({'type': 'error', 'error': '$e'});
  }
  Isolate.exit();
}

class _ReaderArgs {
  final String path;
  final int size;
  final int chunkSize;
  final SendPort sendPort;
  _ReaderArgs({
    required this.path,
    required this.size,
    required this.chunkSize,
    required this.sendPort,
  });
}
