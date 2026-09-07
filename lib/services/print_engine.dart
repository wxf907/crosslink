import 'dart:io';

import 'package:flutter/services.dart';

/// Windows 打印引擎通道封装（com.crosslink.crosslink/print）。
/// 原生实现见 windows/runner/print_channel.cpp。
class PrinterInfo {
  final String name;
  final String port;
  final bool isDefault;
  final bool network;
  final int status;
  const PrinterInfo(
      {required this.name,
      required this.port,
      required this.isDefault,
      required this.network,
      required this.status});

  static PrinterInfo fromMap(Map m) => PrinterInfo(
        name: m['name'] as String? ?? '',
        port: m['port'] as String? ?? '',
        isDefault: m['isDefault'] as bool? ?? false,
        network: m['network'] as bool? ?? false,
        status: (m['status'] as int? ?? 0),
      );
}

class PaperInfo {
  final String name;
  final int wmm;
  final int hmm;
  const PaperInfo({required this.name, required this.wmm, required this.hmm});

  static PaperInfo fromMap(Map m) => PaperInfo(
      name: m['name'] as String? ?? '',
      wmm: m['wmm'] as int? ?? 0,
      hmm: m['hmm'] as int? ?? 0);

  /// IPP media 名称映射（A4/A5/Letter 等常见规格）
  String get ippMedia {
    final n = name.toUpperCase();
    if (n == 'A4' || n == 'ISO A4') return 'iso-a4';
    if (n == 'A5' || n == 'ISO A5') return 'iso-a5';
    if (n == 'B5' || n == 'JIS B5') return 'jis-b5';
    if (n.contains('LETTER')) return 'na-letter';
    if (n.contains('LEGAL')) return 'na-lega';
    if (n.contains('ENVELOPE') && n.contains('#10')) return 'monarch';
    if (n.contains('DL')) return 'iso-designated';
    return 'unknown';
  }
}

class PrinterCaps {
  final bool duplex;
  final bool color;
  final int maxCopies;
  final List<PaperInfo> papers;
  const PrinterCaps(
      {required this.duplex,
      required this.color,
      required this.maxCopies,
      required this.papers});

  static PrinterCaps fromMap(Map m) => PrinterCaps(
        duplex: m['duplex'] as bool? ?? false,
        color: m['color'] as bool? ?? false,
        maxCopies: m['maxCopies'] as int? ?? 1,
        papers: (m['papers'] as List? ?? [])
            .map((e) => PaperInfo.fromMap(e as Map))
            .toList(),
      );
}

/// 打印机三态（与设备列表状态点同一设计语言）
enum PrintState { ready, problem, offline }

class PrintEngine {
  PrintEngine._();
  static final PrintEngine instance = PrintEngine._();

  static bool get supported => Platform.isWindows;

  static const _ch = MethodChannel('com.crosslink.crosslink/print');

  /// jobId → 错误信息（null=成功）。原生打印完成后回调。
  void Function(int jobId, String? error)? onJobDone;

  int _lastStatus = 0;

  Future<void> ensureHandler() async {
    _ch.setMethodCallHandler((call) async {
      if (call.method == 'onPrintEvent') {
        final a = call.arguments as Map;
        if ((a['event'] as String?) == 'jobDone') {
          final err = a['error'] as String?;
          onJobDone?.call(a['jobId'] as int? ?? 0, (err == null || err.isEmpty) ? null : err);
        }
      }
    });
  }

  Future<List<PrinterInfo>> listPrinters() async {
    if (!supported) return const [];
    final r = await _ch.invokeMethod<List<Object?>>('listPrinters');
    return (r ?? []).map((e) => PrinterInfo.fromMap(e as Map)).toList();
  }

  Future<PrinterCaps> printerCaps(String printer) async {
    if (!supported) return const PrinterCaps(duplex: false, color: false, maxCopies: 1, papers: []);
    final r = await _ch.invokeMethod<Map<Object?, Object?>>(
        'printerCaps', {'name': printer});
    return PrinterCaps.fromMap(r ?? const {});
  }

  /// 原始状态位（winspool PRINTER_STATUS_*；0x10000000 = 自定义 WORK_OFFLINE）
  Future<int> printerStatus(String printer) async {
    if (!supported) return -1;
    final r = await _ch.invokeMethod<Map<Object?, Object?>>(
        'printerStatus', {'name': printer});
    _lastStatus = (r?['status'] as int?) ?? -1;
    return _lastStatus;
  }

  /// 按状态位判定三态：
  /// 离线 = WORK_OFFLINE/NOT_AVAILABLE/CLOSED；
  /// 故障 = ERROR/PAPER_JAM/PAPER_OUT/DOOR_OPEN/USER_INTERVENTION/BLOCKED/NO_TONER
  static PrintState stateOf(int status) {
    const offlineBits = 0x10000000 | 0x00000100 | 0x00040000;
    const problemBits =
        0x00000002 | 0x00000008 | 0x00000010 | 0x00400000 | 0x00100000 | 0x00004000 | 0x00000040;
    if (status < 0) return PrintState.offline;
    if ((status & offlineBits) != 0) return PrintState.offline;
    if ((status & problemBits) != 0) return PrintState.problem;
    return PrintState.ready;
  }

  /// 提交打印任务（异步）。jobId 用于关联 onJobDone 回调。
  /// raw100：1:1 纸张原点落位（正式策略，客户端驱动已排版）。
  Future<bool> printPdf({
    required String path,
    required String printer,
    required int jobId,
    int copies = 1,
    String pages = '',
    String duplex = '',
    bool color = false,
    int paperCode = 0,
    bool raw100 = true,
  }) async {
    if (!supported) return false;
    final r = await _ch.invokeMethod<Map<Object?, Object?>>('printPdf', {
      'path': path,
      'printer': printer,
      'jobId': jobId,
      'copies': copies,
      'pages': pages,
      'duplex': duplex,
      'color': color,
      'paperCode': paperCode,
      'raw100': raw100,
    });
    return (r?['accepted'] as bool?) ?? false;
  }
}
