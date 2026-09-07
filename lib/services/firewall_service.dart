import 'dart:io';

import 'package:path/path.dart' as p;

import '../core/constants.dart';
import '../core/logger.dart';

/// Windows 防火墙一键放行：
/// 按【端口】添加入站放行规则（TCP 消息/文件端口 + UDP 发现端口），
/// 而不是按 exe 路径——这样重装、换安装目录、便携版运行都不会让规则失效。
///
/// 检测完全基于 netsh（无 PowerShell / WMI 依赖）：
/// PowerShell 的 Get-NetFirewallRule 在部分机器上启动极慢甚至超时，
/// 会造成"明明已放行却检测为未放行、一键放行后仍报失败"。
/// netsh 的退出码不受系统语言影响，秒级返回。
///
/// 提权方式：以 UAC 提权"自己"（带 --crosslink-add-firewall 参数）执行 netsh，
/// 避免中间脚本/多层引号带来的编码与转义问题。仅 Windows 生效。
class FirewallService {
  FirewallService._();
  static final FirewallService instance = FirewallService._();

  /// 提权实例的命令行参数：添加防火墙规则后立即退出
  static const String addRuleFlag = '--crosslink-add-firewall';

  // 规则名用纯 ASCII，避免任何编码问题；TCP/UDP 分别一条，便于按端口匹配
  static const _ruleTcp = 'CrossLink-TCP';
  static const _ruleUdp = 'CrossLink-UDP';
  // 历史遗留：早期按程序路径添加的规则名，添加时一并清理
  static const _legacyRule = 'CrossLink';

  bool get supported => Platform.isWindows;

  /// 本机入站是否已放行。判定（任一成立即算已放行）：
  /// 1) 我们添加的端口规则（CrossLink-TCP）存在——它必然是
  ///    入站+启用+允许+TCP 47822，退出码为 0 即可，无需解析输出；
  /// 2) 任意入站规则的程序路径指向当前 exe（覆盖旧版路径规则、
  ///    以及系统弹窗放行时自动生成的规则，无论其名字是什么）。
  ///
  /// 判定细节写入运行日志，便于远程排查误报。
  Future<bool> ruleMatches() async {
    if (!supported) return true;
    final r = await _checkWithNetsh();
    log.i('FW',
        '防火墙检查: ${r.ok ? "已放行" : "未放行"} — ${r.detail} (TCP=${AppConst.tcpPort})');
    return r.ok;
  }

  Future<({bool ok, String detail})> _checkWithNetsh() async {
    // 1) 端口规则存在性：退出码 0 = 存在（netsh 按名称匹配，不区分大小写）
    try {
      final t = await Process.run(
        'netsh',
        ['advfirewall', 'firewall', 'show', 'rule', 'name=$_ruleTcp'],
      ).timeout(const Duration(seconds: 15));
      if (t.exitCode == 0) {
        return (ok: true, detail: '端口规则 $_ruleTcp 存在');
      }
    } catch (e) {
      return (ok: false, detail: '查询端口规则异常: $e');
    }

    // 2) 全量入站规则里按当前 exe 路径扫描（路径为纯 ASCII，
    //    不受中文控制台编码影响；输出约 1MB，netsh 通常 2 秒内返回）
    final exeLower = Platform.resolvedExecutable.toLowerCase();
    try {
      final all = await Process.run(
        'netsh',
        [
          'advfirewall', 'firewall', 'show', 'rule',
          'name=all', 'dir=in', 'verbose',
        ],
      ).timeout(const Duration(seconds: 20));
      final out = '${all.stdout}'.toLowerCase();
      if (out.contains(exeLower)) {
        return (ok: true, detail: '入站规则中存在指向当前程序的规则');
      }
      return (ok: false, detail: '未找到端口规则，也没有指向当前程序的入站规则');
    } catch (e) {
      return (ok: false, detail: '查询入站规则列表异常: $e');
    }
  }

  /// 已在管理员上下文时直接添加端口规则（提权实例调用），并写诊断日志
  Future<void> addRuleDirectly() async {
    // TCP 规则同时覆盖消息端口与 IPP 打印端口（netsh 支持逗号端口列表）
    final tcp = '${AppConst.tcpPort},${AppConst.printPort}';
    final udp = '${AppConst.discoveryPort}';
    // 先清理同名端口规则与历史遗留的按程序路径规则，再重建为纯端口规则
    for (final name in [_ruleTcp, _ruleUdp, _legacyRule]) {
      await Process.run(
          'netsh', ['advfirewall', 'firewall', 'delete', 'rule', 'name=$name']);
    }
    final addTcp = await Process.run('netsh', [
      'advfirewall', 'firewall', 'add', 'rule',
      'name=$_ruleTcp', 'dir=in', 'action=allow',
      'enable=yes', 'profile=any', 'protocol=TCP', 'localport=$tcp',
    ]);
    final addUdp = await Process.run('netsh', [
      'advfirewall', 'firewall', 'add', 'rule',
      'name=$_ruleUdp', 'dir=in', 'action=allow',
      'enable=yes', 'profile=any', 'protocol=UDP', 'localport=$udp',
    ]);
    final report = 'TCP=$tcp UDP=$udp\n'
        'tcp add exit=${addTcp.exitCode} out=${addTcp.stdout} err=${addTcp.stderr}\n'
        'udp add exit=${addUdp.exitCode} out=${addUdp.stdout} err=${addUdp.stderr}';
    log.i('FW', report);
    try {
      await File(p.join(Directory.systemTemp.path, 'crosslink_fw_result.txt'))
          .writeAsString(report);
    } catch (_) {}
  }

  /// 现有 TCP 规则是否已包含打印端口（端口数字不受本地化影响，直接搜输出）。
  /// 老版本升级后规则只含 47822，需引导重新放行一次。
  Future<bool> printRuleOk() async {
    if (!supported) return true;
    try {
      final t = await Process.run('netsh',
          ['advfirewall', 'firewall', 'show', 'rule', 'name=$_ruleTcp']);
      if (t.exitCode != 0) return false;
      return '${t.stdout}'.contains('${AppConst.printPort}');
    } catch (_) {
      return false;
    }
  }

  /// 缺失则提权添加。返回最终是否放行成功。
  /// forceAdd=true 用于"规则已存在但要补打印端口"的升级场景：
  /// 跳过已放行早退，复查也按打印端口是否在内判定。
  Future<bool> ensureRule({bool forceAdd = false}) async {
    if (!supported) return true;
    if (!forceAdd && await ruleMatches()) return true;

    // 以 UAC 提权方式重新启动自身（带参数），弹窗显示 CrossLink 图标，
    // 用户点"是"后由提权实例直接执行 netsh，无中间脚本。
    final exe = Platform.resolvedExecutable.replaceAll("'", "''");
    try {
      final r = await Process.run('powershell', [
        '-NoProfile', '-Command',
        "Start-Process -FilePath '$exe' -Verb RunAs -Wait -ArgumentList '$addRuleFlag'"
      ]);
      if (r.exitCode != 0) {
        log.w('FW', '提权启动失败(${r.exitCode}): ${r.stderr}');
      }
    } catch (e) {
      log.w('FW', '提权启动异常: $e');
    }

    // 规则写入与进程退出之间可能有延迟，稍等再复查
    var ok = false;
    for (var i = 0; i < 5 && !ok; i++) {
      await Future.delayed(const Duration(milliseconds: 400));
      ok = forceAdd ? await printRuleOk() : await ruleMatches();
    }
    if (!ok && !forceAdd) {
      // 读取提权实例的诊断日志，便于定位（UAC 未确认 / 非管理员 / 被拦截）
      try {
        final f = File(
            p.join(Directory.systemTemp.path, 'crosslink_fw_result.txt'));
        if (await f.exists()) {
          log.w('FW', '提权实例日志: ${await f.readAsString()}');
        } else {
          log.w('FW', '无提权实例日志：UAC 弹窗可能未确认或账户无管理员权限');
        }
      } catch (_) {}
    }
    log.i('FW', ok ? '防火墙入站规则已添加' : '防火墙规则添加后仍未匹配');
    return ok;
  }
}
