import 'package:flutter/material.dart';

/// 统一的「联系作者 / 请作者喝杯咖啡」面板。
///
/// 入口两处（侧栏底部「联系」、设置页）都调用 [showContactAuthorDialog]，
/// 避免多处重复实现与资源路径散落。
///
/// 布局说明：弹窗高度**由内容决定**（不设 maxHeight、不用弹性填充），
/// 否则二维码会被顶到上方、底部空出一块。
///  - 宽屏（电脑、平板横屏）：支付宝与微信两张码并排
///  - 窄屏（手机竖屏）：切换按钮 + 单张大码，保证便于扫码
Future<void> showContactAuthorDialog(BuildContext context) {
  return showDialog<void>(
    context: context,
    builder: (ctx) => Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 40),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: const ContactAuthorView(),
      ),
    ),
  );
}

enum _Section { contact, sponsor }

class ContactAuthorView extends StatefulWidget {
  const ContactAuthorView({super.key});

  @override
  State<ContactAuthorView> createState() => _ContactAuthorViewState();
}

class _ContactAuthorViewState extends State<ContactAuthorView> {
  static const _contactQr = 'assets/images/wechat_contact_qr.png';

  _Section _section = _Section.contact;

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.primary;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _Seg(
                label: '联系作者',
                icon: Icons.chat_bubble_outline,
                selected: _section == _Section.contact,
                color: color,
                onTap: () => setState(() => _section = _Section.contact),
              ),
              const SizedBox(width: 10),
              _Seg(
                label: '请作者喝杯咖啡',
                icon: Icons.local_cafe_outlined,
                selected: _section == _Section.sponsor,
                color: color,
                onTap: () => setState(() => _section = _Section.sponsor),
              ),
            ],
          ),
          const SizedBox(height: 18),
          if (_section == _Section.contact)
            const _QrBlock(
              image: _contactQr,
              size: 240,
              caption: '微信扫一扫，加作者好友',
              hint: '使用问题、功能建议都可以直接聊',
            )
          else
            const _SponsorBlock(
              alipay: 'assets/images/alipay_qr.png',
              wechat: 'assets/images/wechat_pay_qr.png',
            ),
          Center(
            child: TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('关闭'),
            ),
          ),
        ],
      ),
    );
  }
}

/// 打赏区：宽屏并排两码，窄屏切换单码
class _SponsorBlock extends StatefulWidget {
  final String alipay;
  final String wechat;
  const _SponsorBlock({required this.alipay, required this.wechat});

  @override
  State<_SponsorBlock> createState() => _SponsorBlockState();
}

class _SponsorBlockState extends State<_SponsorBlock> {
  bool _useAlipay = true;

  static const _hint = '扫码请作者喝杯咖啡\n感谢支持，让 CrossLink 持续更新';

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.primary;
    return LayoutBuilder(
      builder: (context, c) {
        if (c.maxWidth >= 440) {
          return Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _QrBlock(
                      image: widget.alipay, size: 190, caption: '支付宝扫码'),
                  _QrBlock(
                      image: widget.wechat, size: 190, caption: '微信扫码'),
                ],
              ),
              const SizedBox(height: 6),
              Text(_hint,
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 12, color: Colors.black54)),
            ],
          );
        }
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                _Seg(
                  label: '支付宝',
                  icon: Icons.account_balance_wallet_outlined,
                  selected: _useAlipay,
                  color: color,
                  onTap: () => setState(() => _useAlipay = true),
                ),
                const SizedBox(width: 10),
                _Seg(
                  label: '微信',
                  icon: Icons.wechat,
                  selected: !_useAlipay,
                  color: color,
                  onTap: () => setState(() => _useAlipay = false),
                ),
              ],
            ),
            const SizedBox(height: 14),
            _QrBlock(
              image: _useAlipay ? widget.alipay : widget.wechat,
              size: 240,
              caption: _useAlipay ? '支付宝扫码' : '微信扫码',
              hint: _hint,
            ),
          ],
        );
      },
    );
  }
}

/// 分段切换按钮
class _Seg extends StatelessWidget {
  final String label;
  final IconData icon;
  final bool selected;
  final Color color;
  final VoidCallback onTap;
  const _Seg({
    required this.label,
    required this.icon,
    required this.selected,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: selected ? color.withValues(alpha: 0.12) : Colors.transparent,
      borderRadius: BorderRadius.circular(20),
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 16, color: selected ? color : Colors.black45),
              const SizedBox(width: 6),
              Text(label,
                  style: TextStyle(
                      fontSize: 13,
                      fontWeight:
                          selected ? FontWeight.w600 : FontWeight.w400,
                      color: selected ? color : Colors.black54)),
            ],
          ),
        ),
      ),
    );
  }
}

/// 二维码 + 说明
class _QrBlock extends StatelessWidget {
  final String image;
  final double size;
  final String caption;
  final String? hint;
  const _QrBlock({
    required this.image,
    required this.size,
    required this.caption,
    this.hint,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(10),
          child: Image.asset(
            image,
            width: size,
            height: size,
            fit: BoxFit.contain,
            errorBuilder: (_, _, _) => Container(
              width: size,
              height: size,
              color: Colors.grey.shade100,
              child: const Center(
                child: Text('二维码图片缺失',
                    style: TextStyle(color: Colors.black38, fontSize: 12)),
              ),
            ),
          ),
        ),
        const SizedBox(height: 8),
        Text(caption,
            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
        if (hint != null) ...[
          const SizedBox(height: 4),
          Text(hint!,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 12, color: Colors.black54)),
        ],
      ],
    );
  }
}

/// 侧栏底部「联系」文字入口
///
/// 位置约定：与「设置」同一行右侧，两端一致，避免占用会话顶栏的注意力。
class ContactEntryButton extends StatelessWidget {
  const ContactEntryButton({super.key});

  @override
  Widget build(BuildContext context) {
    return TextButton(
      onPressed: () => showContactAuthorDialog(context),
      style: TextButton.styleFrom(
        foregroundColor: Colors.black54,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        minimumSize: Size.zero,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
      child: const Text('联系', style: TextStyle(fontSize: 13)),
    );
  }
}
