import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:launch_at_startup/launch_at_startup.dart';
import 'package:provider/provider.dart';

import '../core/constants.dart';
import '../services/background_service.dart';
import '../services/firewall_service.dart';
import '../state/app_state.dart';
import 'contact_author.dart';
import 'diagnostics_page.dart';
import 'hotkey_settings_page.dart';
import 'logs_page.dart';
import 'print_service_page.dart';
import 'qr_pages.dart';

/// 设置页（左下角二级菜单）：设备名、保存路径、通知、扫码授权、日志、账号。
class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      body: ListView(
        children: [
          const _SectionTitle('账号与设备'),
          ListTile(
            leading: _Avatar(path: app.identity?.avatarPath),
            title: const Text('头像'),
            subtitle: const Text('点击从相册/文件选择'),
            trailing: const Icon(Icons.edit, size: 18),
            onTap: () => _pickAvatar(context, app),
          ),
          ListTile(
            leading: const Icon(Icons.account_circle_outlined),
            title: const Text('当前账号'),
            subtitle: Text(app.identity?.accountId ?? ''),
          ),
          ListTile(
            leading: const Icon(Icons.badge_outlined),
            title: const Text('本机设备名称'),
            subtitle: Text(app.identity?.deviceName ?? ''),
            trailing: const Icon(Icons.edit, size: 18),
            onTap: () => _editDeviceName(context, app),
          ),
          SwitchListTile(
            secondary: const Icon(Icons.wifi_tethering),
            title: const Text('启动后自动上线'),
            value: app.settings.autoOnline,
            onChanged: app.setAutoOnline,
          ),
          ListTile(
            leading: Icon(app.online ? Icons.circle : Icons.circle_outlined),
            title: Text(app.online ? '当前在线（点击下线）' : '当前离线（点击上线）'),
            onTap: () => app.online ? app.goOffline() : app.goOnline(),
          ),

          const _SectionTitle('传输'),
          // 桌面端：自选保存目录
          if (AppConst.isDesktop)
            ListTile(
              leading: const Icon(Icons.folder_outlined),
              title: const Text('文件接收保存目录'),
              subtitle: Text(_saveDirLabel(app)),
              trailing: TextButton.icon(
                icon: const Icon(Icons.drive_file_rename_outline, size: 16),
                label: const Text('更改路径'),
                onPressed: () => _pickDir(context, app),
              ),
              onTap: () => _pickDir(context, app),
            ),
          // 安卓端：零权限发布到公共目录（图片进相册、文件进下载）
          if (AppConst.isMobile)
            SwitchListTile(
              secondary: const Icon(Icons.folder_open_outlined),
              title: const Text('收到的文件自动保存到手机'),
              subtitle: Text(app.settings.autoSavePublic
                  ? '图片→相册/CrossLink，文件→下载/CrossLink\n无需授权，文件管理器和相册都能直接看到'
                  : '仅保留在应用内，长按消息可手动「保存到手机」'),
              value: app.settings.autoSavePublic,
              onChanged: app.setAutoSavePublic,
            ),
          SwitchListTile(
            secondary: const Icon(Icons.notifications_active_outlined),
            title: const Text('收到消息/文件时提示'),
            value: app.settings.notifyOnReceive,
            onChanged: app.setNotify,
          ),
          SwitchListTile(
            secondary: const Icon(Icons.photo_outlined),
            title: const Text('会话内图片自动预览'),
            subtitle: const Text('关闭后图片以文件卡片显示'),
            value: app.settings.imagePreview,
            onChanged: app.setImagePreview,
          ),

          // 桌面端：输入与快捷键
          if (AppConst.isDesktop) ...[
            const _SectionTitle('输入与快捷键'),
            SwitchListTile(
              secondary: const Icon(Icons.keyboard_return),
              title: const Text('Enter 键发送消息'),
              subtitle: const Text('开启：Enter 发送，Shift+Enter 换行；关闭：Ctrl+Enter 发送'),
              value: app.settings.enterToSend,
              onChanged: app.setEnterToSend,
            ),
            ListTile(
              leading: const Icon(Icons.crop),
              title: const Text('截图快捷键'),
              subtitle: const Text('自定义全局截图快捷键（默认 Alt+A）'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => const HotkeySettingsPage(),
              )),
            ),
            if (Platform.isWindows)
              ListTile(
                leading: const Icon(Icons.local_fire_department_outlined),
                title: const Text('防火墙一键放行'),
                subtitle: const Text('手机连不上时点此自动添加 Windows 防火墙入站规则'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => _allowFirewall(context),
              ),
          ],

          // 安卓端：后台保活
          if (AppConst.isMobile) ...[
            const _SectionTitle('后台'),
            SwitchListTile(
              secondary: const Icon(Icons.podcasts),
              title: const Text('后台保持在线'),
              subtitle: const Text('开启常驻通知以在后台维持连接（默认开启）'),
              value: app.settings.backgroundOnline,
              onChanged: (v) => _toggleBackground(context, app, v),
            ),
          ],

          const _SectionTitle('外观'),
          ListTile(
            leading: const Icon(Icons.palette_outlined),
            title: const Text('主题色'),
            subtitle: const Text('基础换色，保存后立即生效'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _showThemePicker(context, app),
          ),

          const _SectionTitle('扫码登录'),
          ListTile(
            leading: Icon(AppConst.isMobile
                ? Icons.qr_code_scanner
                : Icons.qr_code_2),
            title: Text(AppConst.isMobile ? '扫一扫（授权其他设备登录）' : '展示二维码（供手机授权）'),
            onTap: () => Navigator.of(context).push(MaterialPageRoute(
              builder: (_) =>
                  AppConst.isMobile ? const QrScanPage() : const QrShowPage(),
            )),
          ),

          const _SectionTitle('诊断'),
          if (Platform.isWindows)
            ListTile(
              leading: const Icon(Icons.network_check_outlined),
              title: const Text('网络诊断'),
              subtitle: const Text('看本机 IP、防火墙状态，测能否连上对方设备'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const DiagnosticsPage()),
              ),
            ),
          ListTile(
            leading: const Icon(Icons.article_outlined),
            title: const Text('运行日志'),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const LogsPage()),
            ),
          ),

          const _SectionTitle('其他'),
          if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) ...[
            ListTile(
              leading: const Icon(Icons.pin_end_outlined),
              title: const Text('关闭主窗口时'),
              subtitle: Text(_closeBehaviorLabel(app)),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => _pickCloseBehavior(context, app),
            ),
            SwitchListTile(
              secondary: const Icon(Icons.rocket_launch_outlined),
              title: const Text('开机自动启动'),
              subtitle: const Text('登录后自动在托盘运行，其他设备随时可连入'),
              value: app.settings.autoStart,
              onChanged: (v) => _setAutoStart(context, app, v),
            ),
            ListTile(
              leading: const Icon(Icons.print_outlined),
              title: const Text('打印服务'),
              subtitle: Text(app.settings.printEnabled
                  ? '共享中：${app.settings.printPrinter.isEmpty ? '未选打印机' : app.settings.printPrinter}'
                  : '让同事经系统打印界面共享本机打印机'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const PrintServicePage()),
              ),
            ),
          ],
            ListTile(
            leading: const Icon(Icons.favorite_outline, color: Colors.pink),
            title: const Text('联系 / 支持作者'),
            subtitle: const Text('加作者微信，或请作者喝杯咖啡'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => showContactAuthorDialog(context),
          ),
          ListTile(
            leading: const Icon(Icons.logout, color: Colors.red),
            title: const Text('退出登录 / 切换账号',
                style: TextStyle(color: Colors.red)),
            onTap: () => _confirmLogout(context, app),
          ),
          const SizedBox(height: 12),
          const Center(
            child: Padding(
              padding: EdgeInsets.all(12),
              child: Text('CrossLink v2.4.0',
                  style: TextStyle(color: Colors.black38, fontSize: 12)),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _editDeviceName(BuildContext context, AppState app) async {
    final ctrl = TextEditingController(text: app.identity?.deviceName ?? '');
    final name = await showDialog<String>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('修改设备名称'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(border: OutlineInputBorder()),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context), child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(context, ctrl.text),
              child: const Text('保存')),
        ],
      ),
    );
    if (name != null && name.trim().isNotEmpty) {
      await app.setDeviceName(name);
    }
  }

  String _closeBehaviorLabel(AppState app) =>
      switch (app.settings.closeBehavior) {
        'quit' => '直接退出',
        'ask' => '每次询问',
        _ => '最小化到系统托盘（双击托盘图标唤回）',
      };

  Future<void> _pickCloseBehavior(BuildContext context, AppState app) async {
    final v = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('关闭主窗口时'),
        content: RadioGroup<String>(
          groupValue: app.settings.closeBehavior,
          onChanged: (x) {
            if (x != null) Navigator.pop(ctx, x);
          },
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final (val, label) in const [
                ('tray', '最小化到系统托盘'),
                ('ask', '每次询问'),
                ('quit', '直接退出程序'),
              ])
                RadioListTile<String>(
                  value: val,
                  title: Text(label),
                ),
            ],
          ),
        ),
      ),
    );
    if (v != null) await app.setCloseBehavior(v);
  }

  Future<void> _setAutoStart(
      BuildContext context, AppState app, bool v) async {
    try {
      launchAtStartup.setup(
        appName: 'CrossLink 跨端互传',
        appPath: Platform.resolvedExecutable,
      );
      v ? await launchAtStartup.enable() : await launchAtStartup.disable();
      await app.setAutoStart(v);
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('设置开机自启失败：$e')));
      }
    }
  }

  Future<void> _pickDir(BuildContext context, AppState app) async {
    final dir = await getDirectoryPath();
    if (dir != null) await app.setSaveDir(dir);
  }

  String _saveDirLabel(AppState app) {
    final dir = app.settings.saveDir ?? '';
    return dir.isEmpty ? '未设置' : dir;
  }

  Future<void> _pickAvatar(BuildContext context, AppState app) async {
    final result = await FilePicker.pickFiles(type: FileType.image);
    final path = result?.files.single.path;
    if (path != null) await app.setAvatar(path);
  }

  Future<void> _toggleBackground(
      BuildContext context, AppState app, bool v) async {
    await app.setBackgroundOnline(v);
    if (v) {
      await BackgroundKeepAlive.instance.start();
    } else {
      await BackgroundKeepAlive.instance.stop();
    }
  }

  /// Windows 防火墙一键放行：全程有进度提示，结束时给出明确结论
  Future<void> _allowFirewall(BuildContext context) async {
    final fw = FirewallService.instance;

    // 1. 检测当前状态（PowerShell 查询约 2~3 秒，必须先给反馈）
    _showBusy(context, '正在检测本机防火墙规则…');
    bool already;
    try {
      already = await fw.ruleMatches();
    } catch (_) {
      already = false;
    }
    if (!context.mounted) return;
    Navigator.of(context).pop(); // 关闭进度

    if (already) {
      await showDialog<void>(
        context: context,
        builder: (_) => AlertDialog(
          icon: const Icon(Icons.verified_user_outlined,
              color: Colors.green, size: 36),
          title: const Text('已经放行'),
          content: const Text('本机防火墙已允许其他设备连入，无需重复操作。'),
          actions: [
            FilledButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('知道了')),
          ],
        ),
      );
      return;
    }

    // 2. 提权添加规则
    _showBusy(context, '正在请求管理员权限\n请在弹出的系统窗口中选择「是」…');
    final ok = await fw.ensureRule();
    if (!context.mounted) return;
    Navigator.of(context).pop();

    await showDialog<void>(
      context: context,
      builder: (_) => AlertDialog(
        icon: Icon(ok ? Icons.check_circle_outline : Icons.error_outline,
            color: ok ? Colors.green : Colors.red, size: 36),
        title: Text(ok ? '放行成功' : '放行失败'),
        content: Text(ok
            ? '已添加防火墙入站规则，其他设备现在可以连入本机。'
            : '没能完成放行。常见原因：\n'
                '· UAC 弹窗点了「否」或超时\n'
                '· 当前账户不是管理员\n'
                '· 被 360/火绒等安全软件拦截\n\n'
                '可再试一次；仍不行请用管理员身份运行本程序后再点，\n'
                '或临时退出安全软件。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('关闭')),
          if (!ok)
            FilledButton(
                onPressed: () {
                  Navigator.pop(context);
                  _allowFirewall(context);
                },
                child: const Text('再试一次')),
        ],
      ),
    );
  }

  /// 不可关闭的进度弹窗（用于耗时操作期间给出反馈）
  void _showBusy(BuildContext context, String text) {
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => AlertDialog(
        content: Row(
          children: [
            const SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(strokeWidth: 2.5)),
            const SizedBox(width: 16),
            Expanded(child: Text(text)),
          ],
        ),
      ),
    );
  }

  /// 基础换色：预设色板，点选即生效；可恢复默认
  static const List<MapEntry<String, int>> _themePresets = [
    MapEntry('QQ 蓝', 0xFF12B7F5),
    MapEntry('微信绿', 0xFF07C160),
    MapEntry('活力橙', 0xFFFF9500),
    MapEntry('星空紫', 0xFF7C4DFF),
    MapEntry('玫瑰红', 0xFFE91E63),
    MapEntry('湖水青', 0xFF009688),
  ];

  void _showThemePicker(BuildContext context, AppState app) {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('主题色'),
        content: SizedBox(
          width: 280,
          child: Wrap(
            spacing: 14,
            runSpacing: 14,
            children: [
              for (final e in _themePresets)
                _ThemeSwatch(
                  label: e.key,
                  color: Color(e.value),
                  selected: app.settings.themeColor == e.value,
                  onTap: () => app.setThemeColor(e.value),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => app.setThemeColor(null),
            child: const Text('恢复默认'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('完成'),
          ),
        ],
      ),
    );
  }

  Future<void> _confirmLogout(BuildContext context, AppState app) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('退出登录'),
        content: const Text('退出后将下线并清除本机登录状态，确定吗？'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('退出')),
        ],
      ),
    );
    if (ok == true) {
      await app.logout();
      if (context.mounted) Navigator.of(context).popUntil((r) => r.isFirst);
    }
  }
}

class _SectionTitle extends StatelessWidget {
  final String text;
  const _SectionTitle(this.text);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 18, 16, 6),
      child: Text(text,
          style: TextStyle(
              fontSize: 13,
              color: Theme.of(context).colorScheme.primary,
              fontWeight: FontWeight.bold)),
    );
  }
}

/// 设置页头像小图
class _Avatar extends StatelessWidget {
  final String? path;
  const _Avatar({required this.path});

  @override
  Widget build(BuildContext context) {
    final p = path;
    if (p != null && p.isNotEmpty && File(p).existsSync()) {
      return CircleAvatar(radius: 18, backgroundImage: FileImage(File(p)));
    }
    return const CircleAvatar(
      radius: 18,
      child: Icon(Icons.person),
    );
  }
}

/// 主题色色块：圆形色板 + 名称，选中显示对勾
class _ThemeSwatch extends StatelessWidget {
  final String label;
  final Color color;
  final bool selected;
  final VoidCallback onTap;
  const _ThemeSwatch({
    required this.label,
    required this.color,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Padding(
        padding: const EdgeInsets.all(4),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: color,
                shape: BoxShape.circle,
                border: selected
                    ? Border.all(color: Colors.black87, width: 3)
                    : null,
              ),
              child: selected
                  ? const Icon(Icons.check, color: Colors.white)
                  : null,
            ),
            const SizedBox(height: 4),
            Text(label, style: const TextStyle(fontSize: 11)),
          ],
        ),
      ),
    );
  }
}
