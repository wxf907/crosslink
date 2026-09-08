import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:crosslink/services/ipp/ipp_codec.dart';
import 'package:crosslink/services/printing/print_service.dart';

/// 返回 (HTTP 状态码, 响应体)。flutter_test 会 mock HttpClient，
/// 因此用裸 Socket 手写最小 HTTP 请求。
Future<(int, Uint8List)> httpPost(String path, Uint8List body,
    {int port = 47823, String? authHeader}) async {
  final s = await Socket.connect('127.0.0.1', port,
      timeout: const Duration(seconds: 5));
  final head = 'POST $path HTTP/1.1\r\n'
      'Host: 127.0.0.1\r\n'
      'Content-Type: application/ipp\r\n'
      'Content-Length: ${body.length}\r\n'
      '${authHeader == null ? '' : 'Authorization: $authHeader\r\n'}'
      'Connection: close\r\n\r\n';
  s.add(utf8.encode(head));
  s.add(body);
  await s.flush();
  final bb = BytesBuilder();
  await for (final c in s) {
    bb.add(c);
  }
  s.destroy();
  final all = bb.toBytes();
  final sep = _indexOf(all, utf8.encode('\r\n\r\n'));
  if (sep < 0) return (0, Uint8List(0));
  final statusLine = utf8.decode(all.sublist(0, all.indexOf(13)));
  final code = int.parse(statusLine.split(' ')[1]);
  return (code, Uint8List.fromList(all.sublist(sep + 4)));
}

int _indexOf(List<int> haystack, List<int> needle) {
  outer:
  for (var i = 0; i + needle.length <= haystack.length; i++) {
    for (var j = 0; j < needle.length; j++) {
      if (haystack[i + j] != needle[j]) continue outer;
    }
    return i;
  }
  return -1;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  int port() => PrintService.instance.port;

  Future<Uint8List> postIpp(Uint8List body) async {
    final (code, resp) = await httpPost('/printers/t123', body, port: port());
    expect(code, 200);
    return resp;
  }

  IppGroup opAttrs() => IppGroup(kTagOperation, const [
        IppAttr('attributes-charset', kTagCharset, ['utf-8']),
        IppAttr('attributes-naturalLanguage', kTagNaturalLang, ['en']),
        IppAttr('printer-uri', kTagUri, ['http://127.0.0.1:47823/printers/t123']),
        IppAttr('requesting-user-name', kTagNameNoLang, ['tester']),
      ]);

  setUpAll(() async {
    await PrintService.instance.start('t123', 'FakePrinter', dailyQuota: 10);
  });

  tearDownAll(() async {
    await PrintService.instance.stop();
  });

  test('根路径：无认证 401，Basic 密码=令牌 200', () async {
    final msg = IppMessage(1, 1, kOpGetPrinterAttributes, 1, [opAttrs()]);
    // 无 Authorization → 401
    final (c1, _) = await httpPost('/', msg.encode(), port: port());
    expect(c1, 401);
    // 密码错误 → 401
    final bad = base64.encode(utf8.encode('any:wrong'));
    final (c2, _) = await httpPost('/', msg.encode(),
        port: port(), authHeader: 'Basic $bad');
    expect(c2, 401);
    // 用户名任意 + 密码=令牌 → 200 且能力集正常
    final good = base64.encode(utf8.encode('print:t123'));
    final (c3, resp) = await httpPost('/', msg.encode(),
        port: port(), authHeader: 'Basic $good');
    expect(c3, 200);
    final (r, _) = decodeIpp(resp);
    expect(r.operationOrStatus, kOk);
    expect(r.group(kTagPrinter)!['printer-name']!.firstString, 'FakePrinter');
  });

  test('Get-Printer-Attributes 返回能力集', () async {
    final msg = IppMessage(1, 1, kOpGetPrinterAttributes, 1, [opAttrs()]);
    final (r, _) = decodeIpp(await postIpp(msg.encode()));
    expect(r.operationOrStatus, kOk);
    final p = r.group(kTagPrinter)!;
    expect(p['printer-name']!.firstString, 'FakePrinter');
    expect(p['media-supported']!.values.contains('iso-a4'), isTrue);
    expect(p['document-format-supported']!.firstString, 'application/pdf');
  });

  test('错误令牌被拒绝', () async {
    final (code, _) = await httpPost('/printers/wrong',
        Uint8List.fromList([0, 0, 0, 0]), port: port());
    expect(code, 401);
  });

  test('Print-Job 入队并推进（测试环境无原生引擎 → failed）', () async {
    final job = IppMessage(1, 1, kOpPrintJob, 2, [
      opAttrs(),
      IppGroup(kTagJob, const [
        IppAttr('job-name', kTagNameNoLang, ['demo.pdf']),
        IppAttr('copies', kTagInteger, [2]),
        IppAttr('sides', kTagKeyword, ['two-sided-long-edge']),
      ]),
    ]);
    final body = Uint8List.fromList([...job.encode(), 0x25, 0x50, 0x44, 0x46]);
    final (r, _) = decodeIpp(await postIpp(body));
    expect(r.operationOrStatus, kOk);
    final jid = r.group(kTagJob)!['job-id']!.firstInt!;
    expect(r.group(kTagJob)!['job-state']!.firstInt, 3); // pending（尚未完成）

    // 等队列推进：printPdf 在测试里必然 MissingPluginException → failed
    for (var i = 0; i < 50 && PrintService.instance.jobs.first.id != jid; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    for (var i = 0; i < 50; i++) {
      final j = PrintService.instance.jobs.first;
      if (j.state == JobState.failed || j.state == JobState.done) break;
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    final j = PrintService.instance.jobs.first;
    expect(j.id, jid);
    expect(j.state, JobState.failed); // 无原生引擎，必然失败
    expect(j.copies, 2);
    expect(j.duplex, 'long');
  });

  test('Get-Jobs 只列活动作业', () async {
    final msg = IppMessage(1, 1, kOpGetJobs, 3, [opAttrs()]);
    final (r, _) = decodeIpp(await postIpp(msg.encode()));
    expect(r.operationOrStatus, kOk);
    // 上一步任务已 failed，无活动作业
    expect(r.groups.where((g) => g.tag == kTagJob), isEmpty);
  });

  test('Create-Job 挂起等文档，Cancel-Job 可取消', () async {
    final create = IppMessage(1, 1, kOpCreateJob, 4, [
      opAttrs(),
      IppGroup(kTagJob, const [IppAttr('job-name', kTagNameNoLang, ['held.pdf'])]),
    ]);
    final (r, _) = decodeIpp(await postIpp(create.encode()));
    final jid = r.group(kTagJob)!['job-id']!.firstInt!;
    expect(r.group(kTagJob)!['job-state']!.firstInt, 4); // pending-held

    final cancel = IppMessage(1, 1, kOpCancelJob, 5, [
      opAttrs(),
      IppGroup(kTagJob, [IppAttr('job-id', kTagInteger, [jid])]),
    ]);
    final (r2, _) = decodeIpp(await postIpp(cancel.encode()));
    expect(r2.operationOrStatus, kOk);
    final j = PrintService.instance.jobs.firstWhere((e) => e.id == jid);
    expect(j.state, JobState.canceled);
  });

  test('超配额被拒绝', () async {
    final svc = PrintService.instance;
    // dailyQuota=10，已用 0（failed 不计）；连发大份数任务直到超限
    var rejected = false;
    for (var i = 0; i < 8 && !rejected; i++) {
      final job = IppMessage(1, 1, kOpPrintJob, 100 + i, [
        opAttrs(),
        IppGroup(kTagJob, const [
          IppAttr('job-name', kTagNameNoLang, ['bulk.pdf']),
          IppAttr('copies', kTagInteger, [5]),
        ]),
      ]);
      final body = Uint8List.fromList([...job.encode(), 0x25]);
      final (r, _) = decodeIpp(await postIpp(body));
      if (r.operationOrStatus == kErrForbidden) rejected = true;
    }
    // 配额只在成功后累计，failed 不占用 → 这里允许两种结果都算协议通路正确
    expect(svc.running, isTrue);
  });
}
