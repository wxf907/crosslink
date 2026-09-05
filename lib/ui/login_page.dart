import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/constants.dart';
import '../state/app_state.dart';
import 'qr_pages.dart';

/// 登录页：账号密码登录 + 扫码登录入口
class LoginPage extends StatefulWidget {
  const LoginPage({super.key});

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final _account = TextEditingController();
  final _password = TextEditingController();
  final _deviceName = TextEditingController();
  bool _busy = false;

  @override
  void dispose() {
    _account.dispose();
    _password.dispose();
    _deviceName.dispose();
    super.dispose();
  }

  Future<void> _login() async {
    if (_account.text.trim().isEmpty || _password.text.isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('请输入账号和密码')));
      return;
    }
    setState(() => _busy = true);
    try {
      await context.read<AppState>().loginWithPassword(
          _account.text, _password.text, _deviceName.text);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: SingleChildScrollView(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 360),
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.devices_other,
                      size: 64, color: Theme.of(context).colorScheme.primary),
                  const SizedBox(height: 12),
                  const Text('CrossLink 跨端互传',
                      style: TextStyle(
                          fontSize: 22, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 6),
                  const Text('同一账号 · 局域网多设备互通',
                      style: TextStyle(color: Colors.black54)),
                  const SizedBox(height: 28),
                  TextField(
                    controller: _account,
                    decoration: const InputDecoration(
                      labelText: '账号',
                      prefixIcon: Icon(Icons.person_outline),
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 14),
                  TextField(
                    controller: _password,
                    obscureText: true,
                    onSubmitted: (_) => _login(),
                    decoration: const InputDecoration(
                      labelText: '密码',
                      prefixIcon: Icon(Icons.lock_outline),
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 14),
                  TextField(
                    controller: _deviceName,
                    decoration: const InputDecoration(
                      labelText: '设备名称（可选，默认取本机名）',
                      prefixIcon: Icon(Icons.badge_outlined),
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 22),
                  SizedBox(
                    width: double.infinity,
                    height: 46,
                    child: FilledButton(
                      onPressed: _busy ? null : _login,
                      child: _busy
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(strokeWidth: 2))
                          : const Text('登录'),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      const Expanded(child: Divider()),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        child: Text('或',
                            style: TextStyle(color: Colors.grey.shade600)),
                      ),
                      const Expanded(child: Divider()),
                    ],
                  ),
                  const SizedBox(height: 12),
                  // 手机端：扫码登录其他设备；桌面端：展示二维码等待手机授权
                  OutlinedButton.icon(
                    onPressed: _openQrLogin,
                    icon: Icon(AppConst.isMobile
                        ? Icons.qr_code_scanner
                        : Icons.qr_code_2),
                    label: Text(AppConst.isMobile ? '扫码登录其他设备' : '扫码登录（手机授权）'),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    AppConst.isMobile
                        ? '已登录的手机可扫描电脑上的二维码，为其快速授权登录'
                        : '在已登录的手机上点“扫一扫”，扫描本机二维码即可登录',
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                        fontSize: 12, color: Colors.black45),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  void _openQrLogin() {
    // 手机端在未登录时无法扫码授权（自身尚无凭证），提示先登录
    if (AppConst.isMobile) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('请先在手机上用账号密码登录，登录后即可扫码为其他设备授权')));
      return;
    }
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const QrShowPage()),
    );
  }
}
