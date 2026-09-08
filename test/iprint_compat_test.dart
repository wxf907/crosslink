import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:crosslink/services/ipp/ipp_codec.dart';
import 'package:crosslink/services/printing/print_service.dart';

/// Windows IPrint（Internet Print Provider）兼容性回归：
/// 它以 IPP/1.0 发请求 —— value-length 是 16 位、end-of-attributes 是 0x03，
/// 与 1.1 的 32 位长度不同。曾因此解码越界返回 HTTP 500，
/// 表现为"Windows 无法连接到打印机（名称无效）"。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late int port;

  setUpAll(() async {
    await PrintService.instance.start('t123', 'FakePrinter', port: 0);
    port = PrintService.instance.port;
  });

  tearDownAll(() async {
    await PrintService.instance.stop();
  });

  List<int> attr10(int tag, String name, String val) {
    final n = name.codeUnits;
    final v = val.codeUnits;
    return [
      tag,
      (n.length >> 8) & 0xFF, n.length & 0xFF,
      ...n,
      (v.length >> 8) & 0xFF, v.length & 0xFF, // 1.0 = 16 位长度
      ...v,
    ];
  }

  int findSep(Uint8List b) {
    for (var i = 0; i + 3 < b.length; i++) {
      if (b[i] == 13 && b[i + 1] == 10 && b[i + 2] == 13 && b[i + 3] == 10) {
        return i + 4;
      }
    }
    return b.length;
  }

  Future<Uint8List> rawIpp(List<int> body) async {
    final head = 'POST /printers/t123 HTTP/1.1\r\n'
        'Connection: Keep-Alive\r\n'
        'Content-Type: application/ipp\r\n'
        'User-Agent: Internet Print Provider\r\n'
        'Content-Length: ${body.length}\r\n'
        'Host: 127.0.0.1:$port\r\n\r\n';
    final s = await Socket.connect('127.0.0.1', port);
    s.add([...head.codeUnits, ...body]);
    await s.flush();
    final bb = BytesBuilder();
    final done = Completer<void>();
    s.listen((d) => bb.add(d), onDone: () {
      if (!done.isCompleted) done.complete();
    });
    await done.future.timeout(const Duration(seconds: 5), onTimeout: () {});
    s.destroy();
    final resp = bb.toBytes();
    final i = resp.indexOf(0x0d);
    final status = String.fromCharCodes(resp.sublist(0, i));
    if (!status.contains('200')) {
      throw StateError('HTTP $status');
    }
    final sep = findSep(resp);
    return Uint8List.fromList(resp.sublist(sep));
  }

  test('IPP/1.0 Get-Printer-Attributes（IPrint 帧格式）', () async {
    final body = <int>[
      1, 0, 0x00, 0x0B, 0, 0, 0, 0x0B,
      0x01,
      ...attr10(0x47, 'attributes-charset', 'utf-8'),
      ...attr10(0x48, 'attributes-natural-language', 'en-us'),
      ...attr10(0x45, 'printer-uri', 'http://127.0.0.1:$port/printers/t123'),
      0x03,
    ];
    final resp = await rawIpp(body);
    final (msg, _) = decodeIpp(resp);
    expect(msg.versionMajor, 1);
    expect(msg.versionMinor, 0); // 版本回显
    expect(msg.operationOrStatus, kOk);
    expect(msg.group(kTagPrinter)!['printer-name']!.firstString, 'FakePrinter');
    // 1.0 响应里 value-length 也是 16 位：若按 32 位解析会越界/错乱
    expect(msg.group(kTagPrinter)!['media-supported']!.values.isNotEmpty, isTrue);
  });

  test('IPP/1.1 请求仍回显 1.1', () async {
    final m = IppMessage(1, 1, kOpGetPrinterAttributes, 9, [
      IppGroup(kTagOperation, const [
        IppAttr('attributes-charset', kTagCharset, ['utf-8']),
        IppAttr('attributes-natural-language', kTagNaturalLang, ['en']),
        IppAttr('printer-uri', kTagUri, ['http://127.0.0.1/printers/t123']),
      ]),
    ]);
    final resp = await rawIpp(m.encode());
    final (msg, _) = decodeIpp(resp);
    expect(msg.versionMinor, 1);
    expect(msg.operationOrStatus, kOk);
  });
}
