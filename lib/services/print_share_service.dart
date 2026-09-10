import 'dart:io';
import 'dart:math';

import '../core/logger.dart';

/// Windows 原生 SMB 打印共享的自动化封装（2.4.0）。
///
/// 为什么走 SMB 而不是 IPP：Win10 的 IPP 客户端（IPrint/CIM）对自建 IPP 服务器
/// 支持残缺（Add-Printer 不支持 IPP URL、向导类安装器校验苛刻），而 SMB 打印共享
/// 是 Windows 原生成熟栈，"名称+密码"即连。本服务把"建专用账户/共享/防火墙"
/// 这些手工步骤全部自动化。
class PrintShareService {
  /// 专用打印账户（仅网络打印用途，禁止交互登录）
  static const accountName = 'clprint';

  /// 固定共享名
  static const shareName = 'CrossLinkPrint';

  static const _resultFile = 'crosslink_share_result.txt';

  static String get _resultPath =>
      '${Directory.systemTemp.path}${Platform.pathSeparator}$_resultFile';

  /// 生成连接串：\\IP\共享名 主机\账户 密码（同事端粘贴即用）。
  /// 使用主机限定账户名，避免 Windows 把 clprint 解析成本机/域账户。
  static String buildSpec(String hostIp, String password) =>
      '\\\\$hostIp\\$shareName $hostIp\\$accountName $password';

  /// 12 位随机密码（去掉易混字符）
  static String newSharePassword() {
    const chars = 'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnpqrstuvwxyz23456789';
    final r = Random.secure();
    return List.generate(12, (_) => chars[r.nextInt(chars.length)]).join();
  }

  // ---------------- 主机端 ----------------

  /// 提权执行共享配置；返回 (成功, 结果文本)
  static Future<(bool, String)> enableShare(String printer, String password) async {
    if (!Platform.isWindows) return (false, '仅 Windows 支持');
    String psQuote(String value) => value.replaceAll("'", "''");
    final script = '''
\$ErrorActionPreference = 'Continue'
\$log = '${_resultPath.replaceAll('\\', '\\\\')}'
"=== \$(Get-Date -Format 'HH:mm:ss') ===" | Set-Content \$log
\$printer = '${psQuote(printer)}'
\$pass = '${psQuote(password)}'
# 1) 专用本地账户（存在则改密码）
\$u = net user $accountName \$pass /add /passwordchg:no /comment:"CrossLink print-only" 2>&1
"account add: \$u" | Add-Content \$log
if (\$LASTEXITCODE -ne 0) {
  \$u2 = net user $accountName \$pass 2>&1
  "account setpass: \$u2" | Add-Content \$log
}
# 2) 禁止该账户本地/远程交互登录（仅保留网络访问）
try {
  \$sid = (Get-LocalUser -Name '$accountName').SID.Value
  \$inf = "\$env:TEMP\\cl_secpol.inf"
  secedit /export /cfg \$inf /quiet 2>&1 | Out-Null
  \$txt = Get-Content \$inf -Raw
  foreach (\$right in @('SeDenyInteractiveLogonRight','SeDenyRemoteInteractiveLogonRight')) {
    if (\$txt -match "\$right\\s*=\\s*(.*)") {
      \$cur = \$Matches[1].Trim()
      if (\$cur -notlike "*\$sid*") {
        \$new = if (\$cur) { "\$cur,*\$sid" } else { "*\$sid" }
        \$txt = \$txt -replace "\$right\\s*=.*", "\$right = \$new"
      }
    } else {
      \$txt = \$txt -replace '\\[Privilege Rights\\]', "[Privilege Rights]`n\$right = *\$sid"
    }
  }
  Set-Content \$inf \$txt
  secedit /configure /cfg \$inf /quiet 2>&1 | Out-Null
  "secedit: exit \$LASTEXITCODE" | Add-Content \$log
} catch { "secedit skip: \$_" | Add-Content \$log }
# 3) 共享打印机
\$s = rundll32 printui.dll,PrintUIEntry /Xs /n "\$printer" ShareName=$shareName 2>&1
\$shareExit = \$LASTEXITCODE
"share: \$s exit \$shareExit" | Add-Content \$log
if (\$shareExit -ne 0) { throw "打印机共享失败（exit=\$shareExit）：\$s" }
# 4) 启用"文件和打印机共享"防火墙组
\$f = netsh advfirewall firewall set rule group="File and Printer Sharing" new enable=yes 2>&1
\$fwExit = \$LASTEXITCODE
"fw: \$f exit \$fwExit" | Add-Content \$log
if (\$fwExit -ne 0) { throw "防火墙放行失败（exit=\$fwExit）：\$f" }
"done" | Add-Content \$log
''';
    final ps = File('${Directory.systemTemp.path}${Platform.pathSeparator}cl_share_setup.ps1');
    await ps.writeAsString(script);
    try {
      await File(_resultPath).delete();
    } catch (_) {}
    final scriptPath = ps.path.replaceAll("'", "''");
    try {
      await Process.run('powershell', [
        '-NoProfile', '-Command',
        "Start-Process powershell -Verb RunAs -Wait -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File','$scriptPath'"
      ]);
    } catch (e) {
      log.w('SHARE', '提权启动异常: $e');
    }
    // 等结果文件
    String text = '';
    for (var i = 0; i < 20; i++) {
      await Future.delayed(const Duration(milliseconds: 500));
      try {
        text = await File(_resultPath).readAsString();
        if (text.contains('done')) break;
      } catch (_) {}
    }
    try {
      await ps.delete();
    } catch (_) {}
    final ok = text.contains('done');
    log.i('SHARE', ok ? '共享配置完成' : '共享配置未完成:\n$text');
    return (ok, text);
  }

  /// 当前共享是否已建立
  static Future<bool> isShared() async {
    if (!Platform.isWindows) return false;
    final r = await Process.run('net', ['share', shareName]);
    return r.exitCode == 0;
  }

  // ---------------- 同事端 ----------------

  /// 从连接串安装：\\IP\共享名 账户 密码
  static Future<(bool, String)> installFromSpec(String spec) async {
    if (!Platform.isWindows) return (false, '仅 Windows 支持');
    final parts = spec.trim().split(RegExp(r'\s+'));
    if (parts.length != 3 || !parts[0].startsWith('\\\\')) {
      return (false, '格式应为：\\\\IP\\共享名 账户 密码');
    }
    final unc = parts[0];
    final rawUser = parts[1];
    final pass = parts[2];
    final host = unc.substring(2).split('\\').first;
    // 本机账户必须明确绑定到共享主机，否则 Windows 可能按当前域/本机解析。
    final user = rawUser.contains('\\') ? rawUser : '$host\\$rawUser';
    final k = await Process.run(
        'cmdkey', ['/add:$host', '/user:$user', '/pass:$pass']);
    if (k.exitCode != 0) {
      return (false, '凭据写入失败：${k.stderr}');
    }
    // WScript.Network 在部分 Win10 版本只返回通用 COM 错误；保留
    // PrintUIEntry 作为同机的原生回退，避免“凭据已写入但打印机未添加”。
    final w = await Process.run('powershell', [
      '-NoProfile', '-Command',
      "(New-Object -ComObject WScript.Network).AddPrinterConnection('$unc')"
    ]);
    if (w.exitCode != 0) {
      final p = await Process.run('rundll32', [
        'printui.dll,PrintUIEntry', '/in', '/n', unc
      ]);
      if (p.exitCode != 0) {
        await Process.run('cmdkey', ['/delete:$host']);
        final err = '${w.stderr} ${p.stderr}'.trim();
        return (false, err.isEmpty ? '添加失败（网络不通、权限或共享名错误）' : err);
      }
    }
    return (true, '');
  }
}
