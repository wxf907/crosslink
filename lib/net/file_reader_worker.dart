import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

/// 文件读取 worker：把磁盘读取从 UI 主线程挪走（大文件传输卡界面的主因）。
///
/// 协议（worker → 主线程，按序到达）：
///   {type:'chunk', offset, bytes}  每块一条
///   {type:'done', total}           读完全部
///   {type:'error', error}          读取失败
///
/// 主线程只做 socket 写（异步非阻塞），磁盘 I/O 不再挤占 UI 线程。
/// worker 结束自然退出（Isolate.exit），无 onExit 监听（该 Dart 版本
/// 的 spawn 不支持），以 done/error 消息作为收尾信号，附超时保护。
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
        onChunk(msg['bytes'] as Uint8List, msg['offset'] as int);
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
      while (offset < args.size) {
        final n = (args.size - offset) < args.chunkSize
            ? (args.size - offset)
            : args.chunkSize;
        final chunk = raf.readSync(n);
        if (chunk.isEmpty) break;
        out.send({'type': 'chunk', 'offset': offset, 'bytes': chunk});
        offset += chunk.length;
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
