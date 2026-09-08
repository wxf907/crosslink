import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart';

import '../../core/constants.dart';
import '../../core/logger.dart';
import '../ipp/ipp_codec.dart';
import '../print_engine.dart';

enum JobState { queued, held, printing, done, failed, canceled }

class PrintJob {
  final int id;
  final String clientName;
  final String fileName;
  final int copies;
  final String pages; // "1-3,5"，空=全部
  final String duplex; // '' | long | short
  final bool color;
  final int paperCode;
  final int estimatedPages; // 配额口径：copies × 指定页数（未知按 copies）
  JobState state = JobState.queued;
  String? error;
  String? tempPath;
  final DateTime submittedAt = DateTime.now();
  DateTime? finishedAt;

  PrintJob({
    required this.id,
    required this.clientName,
    required this.fileName,
    required this.copies,
    required this.pages,
    required this.duplex,
    required this.color,
    required this.paperCode,
    required this.estimatedPages,
    this.tempPath,
  });
}

/// 主机端打印服务：IPP(HTTP) 接收 → 串行队列 → 原生引擎静默打印。
/// 仅 Windows 生效；2.3.0 为单共享打印机。
class PrintService extends ChangeNotifier {
  PrintService._();
  static final PrintService instance = PrintService._();

  static const int _maxDocBytes = 60 * 1024 * 1024; // 60MB
  static const int _maxJobsHistory = 100;

  HttpServer? _server;
  int _nextJobId = 1;
  int _nextNativeId = 1000;
  final Map<int, int> _nativeToJob = {};
  final List<PrintJob> _jobs = [];
  bool _processing = false;
  bool _paused = false;

  String _printer = '';
  String _token = '';
  int _dailyQuota = 200;

  // 每日配额计数
  String _quotaDay = '';
  int _quotaUsed = 0;

  final _rng = Random.secure();

  bool get running => _server != null;
  bool get paused => _paused;
  String get printerName => _printer;
  String get token => _token;
  List<PrintJob> get jobs => List.unmodifiable(_jobs.reversed);
  int get queuedCount =>
      _jobs.where((j) => j.state == JobState.queued || j.state == JobState.held).length;

  int get todayPagesUsed {
    _rollQuotaDay();
    return _quotaUsed;
  }

  set dailyQuota(int v) => _dailyQuota = v <= 0 ? 200 : v;

  String newToken() =>
      List.generate(8, (_) => _rng.nextInt(16).toRadixString(16)).join();

  int _port = AppConst.printPort;

  /// 实际监听端口（631 成功或被占回退 47823）
  int get port => _port;

  Future<void> start(String token, String printer,
      {int dailyQuota = 200, int? port}) async {
    if (!PrintEngine.supported) return;
    if (_server != null) await stop();
    if (token.isEmpty) return;
    _dailyQuota = dailyQuota <= 0 ? 200 : dailyQuota;
    HttpServer? s;
    try {
      if (port != null) {
        // 测试注入：0 表示随机端口，避免并行套件抢占 631
        s = await HttpServer.bind(InternetAddress.anyIPv4, port);
        _port = s.port;
      } else {
        // 首选 IPP 标准端口 631：Windows 添加向导默认值，主机名即达
        s = await HttpServer.bind(InternetAddress.anyIPv4, AppConst.printPort);
        _port = AppConst.printPort;
      }
    } catch (_) {
      try {
        s = await HttpServer.bind(
            InternetAddress.anyIPv4, AppConst.printPortAlt);
        _port = AppConst.printPortAlt;
        log.w('PRINT', '631 被占用，回退端口 $_port（同事添加时需手填端口）');
      } catch (e) {
        log.e('PRINT', '打印服务启动失败（631/47823 均不可用）: $e');
        _server = null;
        return;
      }
    }
    _server = s;
    _printer = printer;
    _token = token;
    s.listen(_onHttp, onError: (Object e) => log.e('PRINT', 'http 异常: $e'));
    log.i('PRINT', '打印服务已启动 :$_port printers/$token -> $printer');
    await PrintEngine.instance.ensureHandler();
    PrintEngine.instance.onJobDone = _onNativeDone;
  }

  Future<void> stop() async {
    await _server?.close(force: true);
    _server = null;
    PrintEngine.instance.onJobDone = null;
    notifyListeners();
  }

  void setPrinter(String printer) {
    _printer = printer;
    notifyListeners();
  }

  // ---------------- HTTP / IPP ----------------

  Future<void> _onHttp(HttpRequest req) async {
    final path = req.uri.path;
    if (req.method == 'GET') {
      req.response
        ..statusCode = 200
        ..headers.contentType = ContentType.html
        ..write('<html><body style="font-family:sans-serif">'
            '<h3>CrossLink 打印服务运行中</h3>'
            '<p>本页面用于确认服务在线；打印需在系统中添加网络打印机，'
            '地址为 http://本机IP:$_port/printers/&lt;令牌&gt;（或根路径 + Basic 认证）</p>'
            '</body></html>');
      await req.response.close();
      return;
    }
    if (req.method != 'POST') {
      req.response.statusCode = 404;
      await req.response.close();
      return;
    }
    // 认证：/printers/<令牌> 直接放行；根路径走 Basic（密码=令牌，用户名任意），
    // 让 Windows 像共享打印机一样弹"输入网络凭据"
    var authorized = false;
    if (path.startsWith('/printers/') && path.split('/').last == _token) {
      authorized = true;
    } else if (path == '/' || path == '/printers') {
      final auth = req.headers.value(HttpHeaders.authorizationHeader) ?? '';
      if (auth.startsWith('Basic ')) {
        try {
          final decoded = utf8.decode(base64.decode(auth.substring(6).trim()));
          final sep = decoded.indexOf(':');
          if (sep >= 0 && decoded.substring(sep + 1) == _token) authorized = true;
        } catch (_) {}
      }
      if (!authorized) {
        req.response
          ..statusCode = 401
          ..headers.set(HttpHeaders.wwwAuthenticateHeader,
              'Basic realm="CrossLink Print"')
          ..close();
        log.w('PRINT', '拒绝：Basic 认证失败 ${req.connectionInfo?.remoteAddress.address}');
        return;
      }
    }
    if (!authorized) {
      req.response.statusCode = 401;
      await req.response.close();
      log.w('PRINT', '拒绝：令牌不符 ${req.connectionInfo?.remoteAddress.address}');
      return;
    }
    try {
      final body = await _readBody(req);
      if (body.length < 9) {
        req.response.statusCode = 400;
        await req.response.close();
        return;
      }
      final (msg, docOffset) = decodeIpp(body);
      final doc = body.sublist(docOffset);
      final resp = await _dispatch(msg, doc, req);
      req.response
        ..statusCode = 200
        ..headers.contentType = ContentType('application', 'ipp')
        ..headers.contentLength = resp.length // 避免 chunked，兼容简易客户端
        ..add(resp);
      await req.response.close();
    } catch (e, st) {
      log.e('PRINT', 'IPP 请求处理异常: $e\n$st');
      try {
        req.response.statusCode = 500;
        await req.response.close();
      } catch (_) {}
    }
  }

  Future<Uint8List> _readBody(HttpRequest req) async {
    final b = BytesBuilder();
    await for (final chunk in req) {
      b.add(chunk);
      if (b.length > _maxDocBytes) throw StateError('document too large');
    }
    return b.toBytes();
  }

  Future<Uint8List> _dispatch(IppMessage req, Uint8List doc, HttpRequest http) async {
    final id = req.requestId;
    switch (req.operationOrStatus) {
      case kOpGetPrinterAttributes:
        return _printerAttributesResp(req, http);
      case kOpValidateJob:
        return IppMessage.buildResponse(id, kOk, versionMajor: req.versionMajor, versionMinor: req.versionMinor);
      case kOpPrintJob:
        return _createJobResp(id, req, doc);
      case kOpCreateJob:
        return _createJobResp(id, req, null);
      case kOpSendDocument:
        return _sendDocumentResp(id, req, doc);
      case kOpGetJobs:
        return _getJobsResp(req);
      case kOpGetJobAttributes:
        return _jobAttributesResp(req);
      case kOpCancelJob:
        return _cancelJobResp(req);
      case kOpHoldJob:
        return _holdJobResp(req, true);
      case kOpReleaseJob:
        return _holdJobResp(req, false);
      case kOpPausePrinter:
        setPaused(true);
        return IppMessage.buildResponse(id, kOk, versionMajor: req.versionMajor, versionMinor: req.versionMinor);
      case kOpResumePrinter:
        setPaused(false);
        return IppMessage.buildResponse(id, kOk, versionMajor: req.versionMajor, versionMinor: req.versionMinor);
      default:
        return IppMessage.buildResponse(id, kErrBadRequest, versionMajor: req.versionMajor, versionMinor: req.versionMinor);
    }
  }

  Future<Uint8List> _printerAttributesResp(IppMessage req, HttpRequest http) async {
    final id = req.requestId;
    PrinterCaps caps = const PrinterCaps(
        duplex: false, color: false, maxCopies: 1, papers: []);
    int statusBits = -1;
    try {
      caps = await PrintEngine.instance.printerCaps(_printer);
      statusBits = await PrintEngine.instance.printerStatus(_printer);
    } catch (_) {}
    final host = http.requestedUri.host;
    final uri = 'http://$host:$_port/printers/$_token';

    final media = <Object>[];
    for (final p in caps.papers) {
      final m = p.ippMedia;
      if (m != 'unknown' && !media.contains(m)) media.add(m);
    }
    if (media.isEmpty) media.add('iso-a4');

    final sides = <Object>['one-sided'];
    if (caps.duplex) {
      sides.addAll(['two-sided-long-edge', 'two-sided-short-edge']);
    }
    final colorModes = <Object>['monochrome'];
    if (caps.color) colorModes.add('color');

    final state = PrintEngine.stateOf(statusBits);
    final printerState = state != PrintState.ready
        ? 5
        : (_processing ? 4 : 3); // 3=idle 4=processing 5=stopped

    final grp = IppGroup(kTagPrinter, [
      IppAttr('printer-uri-supported', kTagUri, [uri]),
      const IppAttr('charset', kTagCharset, ['utf-8']),
      const IppAttr('naturalLanguage', kTagNaturalLang, ['en-us']),
      const IppAttr('uri-authentication-supported', kTagKeyword, ['none']),
      const IppAttr('uri-security-supported', kTagKeyword, ['none']),
      const IppAttr('printer-make-and-model', kTagNameNoLang,
          ['CrossLink IPP Printer']),
      const IppAttr('printer-location', kTagNameNoLang, ['']),
      const IppAttr('printer-info', kTagNameNoLang, ['CrossLink 共享打印']),
      IppAttr('printer-name', kTagNameNoLang, [_printer]),
      IppAttr('printer-state', kTagEnum, [printerState]),
      IppAttr('printer-state-reasons', kTagKeyword,
          [state == PrintState.ready ? 'none' : 'printer-error']),
      const IppAttr('printer-is-accepting-jobs', kTagBoolean, [true]),
      IppAttr('queued-job-count', kTagInteger, [queuedCount]),
      IppAttr('media-ready', kTagKeyword, [media.first]),
      IppAttr('media-supported', kTagKeyword, media),
      IppAttr('media-size-supported', kTagInteger, _mediaSizes(caps.papers)),
      IppAttr('media-bottom-margin', kTagInteger, [500]),
      IppAttr('media-top-margin', kTagInteger, [500]),
      IppAttr('media-left-margin', kTagInteger, [500]),
      IppAttr('media-right-margin', kTagInteger, [500]),
      const IppAttr('media-source-supported', kTagKeyword, ['top', 'auto']),
      const IppAttr('media-type-supported', kTagKeyword,
          ['stationery', 'plain', 'lettersheet']),
      IppAttr('sides-supported', kTagKeyword, sides),
      IppAttr('sides-default', kTagKeyword, ['one-sided']),
      IppAttr('print-color-mode-supported', kTagKeyword, colorModes),
      IppAttr('print-color-mode-default', kTagKeyword, ['color']),
      IppAttr('media-default', kTagKeyword, [media.first]),
      IppAttr('printer-up-time', kTagInteger,
          [DateTime.now().millisecondsSinceEpoch ~/ 1000]),
      const IppAttr('printer-config-change-date-time', kTagInteger, [1]),
      IppAttr('job-copies-supported', kTagRangeOfInteger,
          [IppRange(1, caps.maxCopies.clamp(1, 99))]),
      IppAttr('job-copies-ready', kTagInteger, [1]),
      const IppAttr('job-k-octets-supported', kTagRangeOfInteger,
          [IppRange(0, _maxDocBytes)]),
      const IppAttr('page-ranges-supported', kTagBoolean, [true]),
      const IppAttr('document-format-supported', kTagMimeMediaType,
          ['application/pdf']),
      const IppAttr('operations-supported', kTagEnum, [
        kOpPrintJob,
        kOpValidateJob,
        kOpCreateJob,
        kOpSendDocument,
        kOpGetJobs,
        kOpGetJobAttributes,
        kOpCancelJob,
        kOpGetPrinterAttributes,
        kOpHoldJob,
        kOpReleaseJob,
        kOpPausePrinter,
        kOpResumePrinter,
      ]),
      const IppAttr('pdl-override-supported', kTagKeyword, ['attempted']),
      const IppAttr('compression-supported', kTagKeyword, ['none']),
      const IppAttr('job-creation-attributes-supported', kTagKeyword,
          ['copies', 'page-ranges', 'sides', 'print-color-mode', 'media', 'job-name']),
    ]);
    return IppMessage(req.versionMajor, req.versionMinor, kOk, id, [_opAttrs(), grp]).encode();
  }

  /// media-size-supported：每个值为 (宽,高) 两个大端 int32（微米）
  static List<Object> _mediaSizes(List<PaperInfo> papers) {
    Uint8List pair(int wmm, int hmm) {
      final b = ByteData(8)
        ..setInt32(0, wmm * 1000)
        ..setInt32(4, hmm * 1000);
      return b.buffer.asUint8List();
    }
    final out = <Object>[];
    for (final p in papers) {
      if (p.wmm > 0 && p.hmm > 0) out.add(pair(p.wmm, p.hmm));
    }
    if (out.isEmpty) out.add(pair(210, 297)); // 至少 A4
    return out;
  }

  static IppGroup _opAttrs() => IppGroup(kTagOperation, const [
        IppAttr('charset', kTagCharset, ['utf-8']),
        IppAttr('naturalLanguage', kTagNaturalLang, ['en-us']),
      ]);

  static IppGroup _jobAttrs(PrintJob j) => IppGroup(kTagJob, [
        IppAttr('job-id', kTagInteger, [j.id]),
        IppAttr('job-state', kTagEnum, [_ippJobState(j.state)]),
        IppAttr('job-state-reasons', kTagKeyword,
            [j.state == JobState.failed ? 'job-aborted-document' : 'none']),
        IppAttr('job-name', kTagNameNoLang, [j.fileName]),
        IppAttr('job-originating-user-name', kTagNameNoLang, [j.clientName]),
        IppAttr('time-at-creation', kTagInteger,
            [j.submittedAt.millisecondsSinceEpoch ~/ 1000]),
        IppAttr('job-impressions', kTagInteger, [j.estimatedPages]),
        IppAttr('job-impressions-completed', kTagInteger,
            [j.state == JobState.done ? j.estimatedPages : 0]),
      ]);

  static int _ippJobState(JobState s) => switch (s) {
        JobState.queued => 3, // pending
        JobState.held => 4, // pending-held
        JobState.printing => 5, // processing
        JobState.done => 9, // completed
        JobState.failed => 8, // aborted
        JobState.canceled => 7, // canceled
      };

  Uint8List _getJobsResp(IppMessage req) {
    final id = req.requestId;
    final groups = <IppGroup>[_opAttrs()];
    for (final j in _jobs.reversed) {
      final active = j.state == JobState.queued ||
          j.state == JobState.held ||
          j.state == JobState.printing;
      if (active) groups.add(_jobAttrs(j));
    }
    return IppMessage(req.versionMajor, req.versionMinor, kOk, id, groups).encode();
  }

  Uint8List _jobAttributesResp(IppMessage req) {
    final id = req.requestId;
    final jid = req.group(kTagJob)?['job-id']?.firstInt;
    final j = _jobs.firstWhereOrNull((e) => e.id == jid);
    if (j == null) return IppMessage.buildResponse(id, kErrNotFound, versionMajor: req.versionMajor, versionMinor: req.versionMinor);
    return IppMessage(req.versionMajor, req.versionMinor, kOk, id, [_opAttrs(), _jobAttrs(j)]).encode();
  }

  Uint8List _createJobResp(int id, IppMessage req, Uint8List? doc) {
    final op = req.group(kTagOperation);
    final job = req.group(kTagJob);
    final client = op?['requesting-user-name']?.firstString ?? 'guest';
    final name = (job?['job-name']?.firstString ?? 'document').split('/').last;
    final copies = (job?['copies']?.firstInt ?? 1).clamp(1, 99);
    final sides = job?['sides']?.firstString ?? 'one-sided';
    final colorMode = job?['print-color-mode']?.firstString ?? 'monochrome';
    final media = job?['media']?.firstString ?? 'iso-a4';
    final ranges = job?['page-ranges']?.values;
    final pageList = <String>[];
    var selectedPages = 0;
    if (ranges != null) {
      for (final r in ranges) {
        if (r is IppRange) {
          pageList.add(r.lower == r.upper ? '${r.lower}' : '${r.lower}-${r.upper}');
          selectedPages += r.upper - r.lower + 1;
        }
      }
    }
    _rollQuotaDay();
    final estimated = copies * (selectedPages > 0 ? selectedPages : 1);
    if (_quotaUsed + estimated > _dailyQuota) {
      log.w('PRINT', '配额拒绝：今日已用 $_quotaUsed/$_dailyQuota，任务需 $estimated 页');
      return IppMessage(req.versionMajor, req.versionMinor, kErrForbidden, id, [
        IppGroup(kTagOperation, [
          const IppAttr('charset', kTagCharset, ['utf-8']),
          const IppAttr('naturalLanguage', kTagNaturalLang, ['en-us']),
          IppAttr('status-message', kTagNameNoLang, ['今日打印配额已用完（$_dailyQuota 页）']),
        ]),
      ]).encode();
    }
    final j = PrintJob(
      id: _nextJobId++,
      clientName: client,
      fileName: name,
      copies: copies,
      pages: pageList.join(','),
      duplex: sides.endsWith('short-edge')
          ? 'short'
          : sides.endsWith('long-edge')
              ? 'long'
              : '',
      color: colorMode == 'color',
      paperCode: _mediaToCode(media),
      estimatedPages: estimated,
    );
    _jobs.add(j);
    while (_jobs.length > _maxJobsHistory) {
      _jobs.removeAt(0);
    }
    if (doc != null && doc.isNotEmpty) {
      _saveTempAndEnqueue(j, doc);
    } else {
      j.state = JobState.held; // 等 Send-Document
    }
    notifyListeners();
    log.i('PRINT', '新任务 #${j.id} ${j.fileName} ×${j.copies} by ${j.clientName}');
    return IppMessage(req.versionMajor, req.versionMinor, kOk, id, [_opAttrs(), _jobAttrs(j)]).encode();
  }

  Uint8List _sendDocumentResp(int id, IppMessage req, Uint8List doc) {
    final jid = req.group(kTagJob)?['job-id']?.firstInt;
    final j = _jobs.firstWhereOrNull((e) => e.id == jid);
    if (j == null) return IppMessage.buildResponse(id, kErrNotFound, versionMajor: req.versionMajor, versionMinor: req.versionMinor);
    if (doc.isEmpty) return IppMessage.buildResponse(id, kErrBadRequest, versionMajor: req.versionMajor, versionMinor: req.versionMinor);
    j.state = JobState.queued;
    _saveTempAndEnqueue(j, doc);
    return IppMessage(req.versionMajor, req.versionMinor, kOk, id, [_opAttrs(), _jobAttrs(j)]).encode();
  }

  Uint8List _cancelJobResp(IppMessage req) {
    final id = req.requestId;
    final jid = req.group(kTagJob)?['job-id']?.firstInt;
    final j = _jobs.firstWhereOrNull((e) => e.id == jid);
    if (j == null) return IppMessage.buildResponse(id, kErrNotFound, versionMajor: req.versionMajor, versionMinor: req.versionMinor);
    if (j.state == JobState.printing) {
      return IppMessage.buildResponse(id, kErrBadRequest, versionMajor: req.versionMajor, versionMinor: req.versionMinor); // 正在出纸不可取消
    }
    if (j.state == JobState.queued || j.state == JobState.held) {
      j.state = JobState.canceled;
      j.finishedAt = DateTime.now();
      _deleteTemp(j);
      notifyListeners();
      log.i('PRINT', '任务 #${j.id} 已取消（远程）');
    }
    return IppMessage.buildResponse(id, kOk, versionMajor: req.versionMajor, versionMinor: req.versionMinor);
  }

  Uint8List _holdJobResp(IppMessage req, bool hold) {
    final id = req.requestId;
    final jid = req.group(kTagJob)?['job-id']?.firstInt;
    final j = _jobs.firstWhereOrNull((e) => e.id == jid);
    if (j == null) return IppMessage.buildResponse(id, kErrNotFound, versionMajor: req.versionMajor, versionMinor: req.versionMinor);
    if (hold && j.state == JobState.queued) j.state = JobState.held;
    if (!hold && j.state == JobState.held) {
      j.state = JobState.queued;
      _pump();
    }
    notifyListeners();
    return IppMessage.buildResponse(id, kOk, versionMajor: req.versionMajor, versionMinor: req.versionMinor);
  }

  // ---------------- 队列执行 ----------------

  Future<void> _saveTempAndEnqueue(PrintJob j, Uint8List doc) async {
    try {
      final dir = await Directory.systemTemp.createTemp('clprint');
      final f = File('${dir.path}${Platform.pathSeparator}${j.id}_${j.fileName}');
      await f.writeAsBytes(doc, flush: true);
      j.tempPath = f.path;
      _pump();
    } catch (e) {
      _finish(j, JobState.failed, '临时文件写入失败: $e');
    }
  }

  void _pump() {
    if (_processing || _paused) return;
    final next = _jobs.firstWhereOrNull(
        (j) => j.state == JobState.queued && j.tempPath != null);
    if (next == null) return;
    _process(next);
  }

  Future<void> _process(PrintJob j) async {
    _processing = true;
    j.state = JobState.printing;
    notifyListeners();
    try {
      final nativeId = _nextNativeId++;
      _nativeToJob[nativeId] = j.id;
      final ok = await PrintEngine.instance.printPdf(
        path: j.tempPath!,
        printer: _printer,
        jobId: nativeId,
        copies: j.copies,
        pages: j.pages,
        duplex: j.duplex,
        color: j.color,
        paperCode: j.paperCode,
        raw100: true,
      );
      if (!ok) {
        _finish(j, JobState.failed, '引擎拒绝');
      }
      // 成功受理后由 onPrintEvent 回调收尾
    } catch (e) {
      _finish(j, JobState.failed, '$e');
    }
  }

  void _onNativeDone(int nativeId, String? error) {
    final jobId = _nativeToJob.remove(nativeId);
    if (jobId == null) return;
    final j = _jobs.firstWhereOrNull((e) => e.id == jobId);
    if (j == null) return;
    if (j.state == JobState.canceled) {
      _processing = false;
      _pump();
      return;
    }
    _rollQuotaDay();
    if (error == null) _quotaUsed += j.estimatedPages;
    _finish(j, error == null ? JobState.done : JobState.failed, error);
  }

  void _finish(PrintJob j, JobState s, String? error) {
    j.state = s;
    j.error = error;
    j.finishedAt = DateTime.now();
    _deleteTemp(j);
    _processing = false;
    notifyListeners();
    log.i('PRINT', '任务 #${j.id} ${s.name}${error == null ? '' : ' : $error'}');
    _pump();
  }

  void _deleteTemp(PrintJob j) {
    final p = j.tempPath;
    j.tempPath = null;
    if (p == null) return;
    try {
      final f = File(p);
      f.deleteSync();
      f.parent.deleteSync();
    } catch (_) {}
  }

  void _rollQuotaDay() {
    final today = DateTime.now().toIso8601String().substring(0, 10);
    if (_quotaDay != today) {
      _quotaDay = today;
      _quotaUsed = 0;
    }
  }

  /// 主机 UI 主动取消
  void cancelJob(int id) {
    final j = _jobs.firstWhereOrNull((e) => e.id == id);
    if (j == null) return;
    if (j.state == JobState.queued || j.state == JobState.held) {
      j.state = JobState.canceled;
      j.finishedAt = DateTime.now();
      _deleteTemp(j);
      notifyListeners();
    }
  }

  void cancelAll() {
    for (final j in _jobs) {
      if (j.state == JobState.queued || j.state == JobState.held) {
        j.state = JobState.canceled;
        j.finishedAt = DateTime.now();
        _deleteTemp(j);
      }
    }
    notifyListeners();
  }

  void setPaused(bool v) {
    _paused = v;
    notifyListeners();
    if (!v) _pump();
  }

  int _mediaToCode(String media) => switch (media) {
        'iso-a4' => 9,
        'iso-a5' => 11,
        'jis-b5' => 13,
        'na-letter' => 1,
        'na-legal' => 5,
        'monarch' => 20,
        'iso-designated' => 27,
        _ => 9,
      };
}
