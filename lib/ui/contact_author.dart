import 'package:flutter/material.dart';

/// 统一的「联系作者 / 请作者喝杯咖啡」面板。
///
/// 入口两处（侧栏底部「联系」、设置页）都调用 [showContactAuthorDialog]，
/// 避免多处重复实现与资源路径散落。
///
/// 布局策略：
///  - 外层两个标签：联系作者 / 请作者喝杯咖啡（点一次即可切换，不再多级弹窗）
///  - 宽屏（电脑、平板横屏）：支付宝与微信两张码并排
///  - 窄屏（手机竖屏）：内层标签切换，保证单张码足够大、便于扫码
Future<void> showContactAuthorDialog(BuildContext context) {
  return showDialog<void>(
    context: context,
    builder: (ctx) => Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 32),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560, maxHeight: 620),
        child: const ContactAuthorView(),
      ),
    ),
  );
}

class ContactAuthorView extends StatelessWidget {
  const ContactAuthorView({super.key});

  static const _contactQr = 'assets/images/wechat_contact_qr.png';
  static const _alipayQr = 'assets/images/alipay_qr.png';
  static const _wechatPayQr = 'assets/images/wechat_pay_qr.png';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return DefaultTabController(
      length: 2,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TabBar(
            labelColor: theme.colorScheme.primary,
            unselectedLabelColor: Colors.black54,
            indicatorColor: theme.colorScheme.primary,
            tabs: const [
              Tab(
                  child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.chat_bubble_outline, size: 16),
                  SizedBox(width: 6),
                  Text('联系作者'),
                ],
              )),
              Tab(
                  child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.local_cafe_outlined, size: 16),
                  SizedBox(width: 6),
                  Text('请作者喝杯咖啡'),
                ],
              )),
            ],
          ),
          Flexible(
            child: TabBarView(
              children: [
                _QrPage(
                  image: _contactQr,
                  caption: '微信扫一扫，加作者好友',
                  hint: '使用问题、功能建议都可以直接聊\n看到都会回复',
                ),
                _SponsorPage(alipayImage: _alipayQr, wechatImage: _wechatPayQr),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 单张二维码页
class _QrPage extends StatelessWidget {
  final String image;
  final String caption;
  final String hint;
  const _QrPage({
    required this.image,
    required this.caption,
    required this.hint,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _QrImage(path: image, size: 220),
          const SizedBox(height: 12),
          Text(caption,
              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
          const SizedBox(height: 6),
          Text(hint,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 12, color: Colors.black54)),
        ],
      ),
    );
  }
}

/// 打赏页：宽屏并排两码，窄屏内层标签切换
class _SponsorPage extends StatelessWidget {
  final String alipayImage;
  final String wechatImage;
  const _SponsorPage({required this.alipayImage, required this.wechatImage});

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, c) {
        const hint = '扫码请作者喝杯咖啡\n感谢你的支持，让 CrossLink 持续更新';
        if (c.maxWidth >= 460) {
          return Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    _QrWithLabel(
                        image: alipayImage, label: '支付宝', size: 180),
                    _QrWithLabel(image: wechatImage, label: '微信', size: 180),
                  ],
                ),
                const SizedBox(height: 10),
                Text(hint,
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontSize: 12, color: Colors.black54)),
              ],
            ),
          );
        }
        // 窄屏：内层标签，保证单张码够大
        return DefaultTabController(
          length: 2,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const TabBar(
                tabs: [Tab(text: '支付宝'), Tab(text: '微信')],
              ),
              Flexible(
                child: TabBarView(
                  children: [
                    _QrPage(
                        image: alipayImage,
                        caption: '支付宝扫码',
                        hint: hint),
                    _QrPage(image: wechatImage, caption: '微信扫码', hint: hint),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _QrWithLabel extends StatelessWidget {
  final String image;
  final String label;
  final double size;
  const _QrWithLabel(
      {required this.image, required this.label, required this.size});

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _QrImage(path: image, size: size),
        const SizedBox(height: 6),
        Text(label, style: const TextStyle(fontSize: 13)),
      ],
    );
  }
}

/// 二维码图片：资源缺失时给出友好占位而不是红块
class _QrImage extends StatelessWidget {
  final String path;
  final double size;
  const _QrImage({required this.path, required this.size});

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(10),
      child: Image.asset(
        path,
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
    );
  }
}

/// 侧栏底部 / 手机首页底部的「联系」文字入口
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
