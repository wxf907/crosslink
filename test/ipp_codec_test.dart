import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:crosslink/services/ipp/ipp_codec.dart';

Uint8List _attr(int tag, String name, List<int> value) => Uint8List.fromList([
      tag,
      (name.length >> 8) & 0xFF,
      name.length & 0xFF,
      ...utf8.encode(name),
      (value.length >> 24) & 0xFF,
      (value.length >> 16) & 0xFF,
      (value.length >> 8) & 0xFF,
      value.length & 0xFF,
      ...value,
    ]);

void main() {
  test('解码 Get-Printer-Attributes golden 报文', () {
    final bytes = BytesBuilder();
    bytes.add([1, 1]); // version 1.1
    bytes.add([0x00, 0x0B]); // op = Get-Printer-Attributes
    bytes.add([0, 0, 0, 7]); // request-id
    bytes.addByte(kTagOperation);
    bytes.add(_attr(kTagCharset, 'attributes-charset', utf8.encode('utf-8')));
    bytes.add(_attr(kTagNaturalLang, 'attributes-naturalLanguage', utf8.encode('en')));
    bytes.add(_attr(kTagUri, 'printer-uri', utf8.encode('http://127.0.0.1:47823/printers/t1')));
    bytes.addByte(kTagEnd);

    final (msg, docOffset) = decodeIpp(bytes.toBytes());
    expect(msg.versionMajor, 1);
    expect(msg.versionMinor, 1);
    expect(msg.operationOrStatus, kOpGetPrinterAttributes);
    expect(msg.requestId, 7);
    expect(docOffset, bytes.length);
    final op = msg.group(kTagOperation)!;
    expect(op['attributes-charset']!.firstString, 'utf-8');
    expect(op['printer-uri']!.firstString, 'http://127.0.0.1:47823/printers/t1');
  });

  test('编码往返：属性、1setOf、range、bool、int', () {
    final msg = IppMessage(1, 1, kOk, 42, [
      IppGroup(kTagOperation, [
        const IppAttr('attributes-charset', kTagCharset, ['utf-8']),
      ]),
      IppGroup(kTagPrinter, [
        const IppAttr('printer-name', kTagNameNoLang, ['CrossLink HP']),
        const IppAttr('queued-job-count', kTagInteger, [3]),
        const IppAttr('printer-is-accepting-jobs', kTagBoolean, [true]),
        const IppAttr('media', kTagKeyword, ['iso-a4', 'iso-a5', 'na-letter']),
        const IppAttr('job-impactions-supported', kTagRangeOfInteger,
            [IppRange(1, 99)]),
      ]),
    ]);
    final encoded = msg.encode();
    final (decoded, _) = decodeIpp(encoded);
    expect(decoded.operationOrStatus, kOk);
    expect(decoded.requestId, 42);
    final printer = decoded.group(kTagPrinter)!;
    expect(printer['printer-name']!.firstString, 'CrossLink HP');
    expect(printer['queued-job-count']!.firstInt, 3);
    expect(printer['printer-is-accepting-jobs']!.firstBool, true);
    expect(printer['media']!.values, ['iso-a4', 'iso-a5', 'na-letter']);
    expect(printer['job-impactions-supported']!.values.first, const IppRange(1, 99));
  });

  test('Print-Job：属性区后文档字节流可切片取出', () {
    final msg = IppMessage(1, 1, kOpPrintJob, 1, [
      IppGroup(kTagOperation, [
        const IppAttr('printer-uri', kTagUri, ['http://h/printers/x']),
      ]),
      IppGroup(kTagJob, [
        const IppAttr('job-name', kTagNameNoLang, ['demo.pdf']),
        const IppAttr('document-format', kTagMimeMediaType, ['application/pdf']),
      ]),
    ]);
    final body = BytesBuilder()
      ..add(msg.encode())
      ..add([0x25, 0x50, 0x44, 0x46]); // %PDF 头
    final (decoded, offset) = decodeIpp(body.toBytes());
    expect(decoded.operationOrStatus, kOpPrintJob);
    expect(decoded.group(kTagJob)!['job-name']!.firstString, 'demo.pdf');
    final doc = body.toBytes().sublist(offset);
    expect(doc, [0x25, 0x50, 0x44, 0x46]);
  });
}
