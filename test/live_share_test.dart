// 一次性真机验证：走正式代码 PrintShareService 全链路。
// 运行：LIVE=1 flutter test test/live_share_test.dart（默认跳过，防误弹 UAC）
// 注意：会弹 UAC 提权窗口（主机端一键共享的正式行为）。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:crosslink/services/print_share_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('disableShare 停掉实际共享的打印机（不依赖传入的打印机名）', () async {
    final (ok, text) = await PrintShareService.disableShare();
    // ignore: avoid_print
    print('===== disableShare: $ok =====\n$text');
    expect(ok, isTrue, reason: '停止共享应成功：$text');

    final shared = await PrintShareService.sharedPrinter();
    // ignore: avoid_print
    print('===== sharedPrinter after disable: $shared =====');
    expect(shared, isNull, reason: '停止后不应再有挂 CrossLinkPrint 的打印机');
  },
      timeout: const Timeout(Duration(minutes: 3)),
      skip: Platform.environment['LIVE'] == null ? '需 LIVE=1 才运行（会弹 UAC）' : null);

  test('enableShare 重新启用 MG3600（沿用旧密码保证同事端凭据不失效）', () async {
    const printer = 'Canon MG3600 series';
    const password = 'ClLive2026Test';
    final (ok, text) = await PrintShareService.enableShare(printer, password);
    // ignore: avoid_print
    print('===== enableShare: $ok =====\n$text');
    expect(ok, isTrue, reason: '启用共享应成功：$text');

    final shared = await PrintShareService.sharedPrinter();
    // ignore: avoid_print
    print('===== sharedPrinter after enable: $shared =====');
    expect(shared, printer, reason: '应共享 $printer');
  },
      timeout: const Timeout(Duration(minutes: 3)),
      skip: Platform.environment['LIVE'] == null ? '需 LIVE=1 才运行（会弹 UAC）' : null);
}
