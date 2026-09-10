import 'dart:convert';
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
"=== \$(Get-Date -Format 'HH:mm:ss') ===" | Set-Content \$log -Encoding UTF8
\$printer = '${psQuote(printer)}'
\$pass = '${psQuote(password)}'
# 1) 专用本地账户（存在则改密码）
\$u = net user $accountName \$pass /add /passwordchg:no /comment:"CrossLink print-only" 2>&1
"account add: \$u" | Add-Content \$log -Encoding UTF8
if (\$LASTEXITCODE -ne 0) {
  \$u2 = net user $accountName \$pass 2>&1
  "account setpass: \$u2" | Add-Content \$log -Encoding UTF8
}
# 2) 禁止该账户本地/远程交互登录（仅保留网络访问）
# 注：secedit /configure 即使成功也可能返回 exit=1（退出码不可靠），
# 实测以重新导出的策略内容为准；此处失败仅记录不中断。
try {
  \$sid = (Get-LocalUser -Name '$accountName').SID.Value
  \$inf = "\$env:TEMP\\cl_secpol.inf"
  secedit /export /cfg \$inf /quiet 2>&1 | Out-Null
  \$txt = Get-Content \$inf -Raw
  foreach (\$right in @('SeDenyInteractiveLogonRight','SeDenyRemoteInteractiveLogonRight')) {
    if (\$txt -match "\$right\\s*=\\s*(.*)") {
      \$cur = \$Matches[1].Trim()
      if (\$cur -notlike "*\$sid*" -and \$cur -notlike "*$accountName*") {
        \$new = if (\$cur) { "\$cur,*\$sid" } else { "*\$sid" }
        \$txt = \$txt -replace "\$right\\s*=.*", "\$right = \$new"
      }
    } else {
      \$txt = \$txt -replace '\\[Privilege Rights\\]', "[Privilege Rights]`r`n\$right = *\$sid"
    }
  }
  [System.IO.File]::WriteAllText(\$inf, \$txt, [System.Text.Encoding]::Default)
  secedit /configure /cfg \$inf /quiet 2>&1 | Out-Null
  "secedit: exit \$LASTEXITCODE (退出码仅供参考)" | Add-Content \$log -Encoding UTF8
} catch { "secedit skip: \$_" | Add-Content \$log -Encoding UTF8 }
# 3) 共享打印机：Set-Printer（现代 cmdlet，printui /Xs 实测 exit=1 不可靠）
try {
  Set-Printer -Name "\$printer" -Shared \$true -ShareName '$shareName' -ErrorAction Stop
  "share: OK" | Add-Content \$log -Encoding UTF8
} catch { throw "打印机共享失败：\$_" }
# 4) 启用"文件和打印机共享"防火墙组
# 用 PS 原生 Set-NetFirewallRule + 语言无关规范组名 @FirewallAPI.dll,-28502：
# 中文系统组名是"文件和打印机共享"，netsh 英文组名匹配不到任何规则；
# 且 netsh 文本输出是 GBK，写进 UTF-8 日志会乱码
try {
  Get-NetFirewallRule -Group "@FirewallAPI.dll,-28502" -ErrorAction Stop | Set-NetFirewallRule -Enabled True -ErrorAction Stop
  "fw: OK" | Add-Content \$log -Encoding UTF8
} catch {
  throw "防火墙放行失败：\$_"
}
"done" | Add-Content \$log -Encoding UTF8
''';
    final ps = File('${Directory.systemTemp.path}${Platform.pathSeparator}cl_share_setup.ps1');
    // UTF-8 BOM 必须有：PowerShell 5.1 把无 BOM 的 .ps1 按 ANSI/GBK 解析，
    // 脚本里的中文注释会直接导致 ParseError（实测主机端"一键启用"从未成功即此因）
    await ps.writeAsString('\uFEFF$script');
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
  /// 不用 `net share`：它对打印机共享的枚举在不同 Windows 版本上不可靠，
  /// 直接查打印机对象的 Shared/ShareName 属性最准确。
  static Future<bool> isShared() async => await sharedPrinter() != null;

  /// 返回当前挂 CrossLinkPrint 共享名的打印机名；未共享返回 null。
  /// 注意与"用户选的打印机"可能不一致（共享后用户又切换了下拉选择），
  /// 停止共享必须以这个实际共享的打印机为准，否则会停错对象。
  static Future<String?> sharedPrinter() async {
    if (!Platform.isWindows) return null;
    final r = await Process.run('powershell', [
      '-NoProfile', '-Command',
      "[Console]::OutputEncoding=[System.Text.Encoding]::UTF8; "
      "(Get-Printer | Where-Object {\$_.Shared -and \$_.ShareName -eq '$shareName'} | "
      "Select-Object -First 1 -ExpandProperty Name)"
    ], stdoutEncoding: utf8, stderrEncoding: utf8);
    if (r.exitCode != 0) return null;
    final name = (r.stdout as String).trim();
    return name.isEmpty ? null : name;
  }

  /// 停止共享（总开关的"关"侧）：取消打印机共享。
  /// 不指定打印机——直接停掉所有挂着 CrossLinkPrint 共享名的打印机，
  /// 避免因"用户选择的打印机"与"实际共享的打印机"不一致而停错对象
  /// （实测踩坑：手动切过共享后设置里仍是旧打印机，停了旧的、新的照常共享）。
  /// 专用账户 clprint 与防火墙放行保留不动——下次启用一步到位，
  /// 且账户不用于其他用途（已禁止交互登录），留着没有风险。
  static Future<(bool, String)> disableShare() async {
    if (!Platform.isWindows) return (false, '仅 Windows 支持');
    final script = '''
\$ErrorActionPreference = 'Continue'
\$log = '${_resultPath.replaceAll('\\', '\\\\')}'
"=== \$(Get-Date -Format 'HH:mm:ss') ===" | Set-Content \$log -Encoding UTF8
\$targets = @(Get-Printer | Where-Object {\$_.Shared -and \$_.ShareName -eq '$shareName'})
if (\$targets.Count -eq 0) {
  "nothing to unshare" | Add-Content \$log -Encoding UTF8
} else {
  foreach (\$t in \$targets) {
    try {
      Set-Printer -Name \$t.Name -Shared \$false -ErrorAction Stop
      "unshared: \$(\$t.Name)" | Add-Content \$log -Encoding UTF8
    } catch { throw "取消共享失败（\$(\$t.Name)）：\$_" }
  }
}
"done" | Add-Content \$log -Encoding UTF8
''';
    final ps = File('${Directory.systemTemp.path}${Platform.pathSeparator}cl_share_stop.ps1');
    // BOM 必须：PowerShell 5.1 对无 BOM 脚本按 GBK 解析（同 enableShare 的教训）
    await ps.writeAsString('\uFEFF$script');
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
    log.i('SHARE', ok ? '已停止共享' : '停止共享未完成:\n$text');
    return (ok, text);
  }

  // ---------------- 同事端 ----------------

  /// 2021 年 PrintNightmare 补丁后，普通权限连接共享打印机装驱动会被拒，
  /// 典型报错 0x0000011b / 0x00000709。修复方式是放开客户端
  /// RestrictDriverInstallationToAdministrators（需管理员，弹一次 UAC）。
  static const _ppKey =
      r'HKLM\SOFTWARE\Policies\Microsoft\Windows NT\Printers\PointAndPrint';

  static Future<bool> _fixDriverInstallRestriction() async {
    final ps = File(
        '${Directory.systemTemp.path}${Platform.pathSeparator}cl_pp_fix.ps1');
    // 同上：BOM 防 GBK 解析问题（必须位于文件首字节）
    await ps.writeAsString('\uFEFF'
        'reg add "$_ppKey" /v RestrictDriverInstallationToAdministrators /t REG_DWORD /d 0 /f\n');
    try {
      final scriptPath = ps.path.replaceAll("'", "''");
      await Process.run('powershell', [
        '-NoProfile', '-Command',
        "Start-Process powershell -Verb RunAs -Wait -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File','$scriptPath'"
      ]);
    } catch (_) {
    } finally {
      try {
        await ps.delete();
      } catch (_) {}
    }
    // 读回验证
    final r = await Process.run('reg', ['query', _ppKey, '/v',
        'RestrictDriverInstallationToAdministrators']);
    final out = '${r.stdout}${r.stderr}';
    return out.contains('0x0');
  }

  /// 添加打印机；失败时自动修复非管理员装驱动限制后重试一次。
  static Future<(bool, String)> _addPrinterWithRetry(String unc) async {
    var w = await Process.run('powershell', [
      '-NoProfile', '-Command',
      "(New-Object -ComObject WScript.Network).AddPrinterConnection('$unc')"
    ]);
    if (w.exitCode == 0) return (true, '');
    var err = '${w.stderr}'.trim();
    // 典型拒绝码：0x0000011b（策略限制非管理员装驱动）/ 0x00000709
    if (err.contains(RegExp(r'0x00000(11b|709)', caseSensitive: false))) {
      final fixed = await _fixDriverInstallRestriction();
      log.i('SHARE', '检测到驱动安装限制，修复${fixed ? '成功' : '失败'}，重试添加');
      if (fixed) {
        w = await Process.run('powershell', [
          '-NoProfile', '-Command',
          "(New-Object -ComObject WScript.Network).AddPrinterConnection('$unc')"
        ]);
        if (w.exitCode == 0) return (true, '');
        err = '${w.stderr}'.trim();
      }
    }
    // WScript.Network 在部分 Win10 版本只返回通用 COM 错误；保留
    // PrintUIEntry 作为同机的原生回退，避免“凭据已写入但打印机未添加”。
    final p = await Process.run('rundll32', [
      'printui.dll,PrintUIEntry', '/in', '/n', unc
    ]);
    if (p.exitCode != 0) {
      final combined = '$err ${p.stderr}'.trim();
      return (false,
          combined.isEmpty ? '添加失败（网络不通、权限或共享名错误）' : combined);
    }
    return (true, '');
  }

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
    final (ok, err) = await _addPrinterWithRetry(unc);
    if (!ok) {
      await Process.run('cmdkey', ['/delete:$host']);
      return (false, err);
    }
    return (true, '');
  }
}
