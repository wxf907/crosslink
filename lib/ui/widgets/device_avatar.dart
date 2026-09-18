import 'package:flutter/material.dart';

import '../../core/constants.dart';
import '../../state/app_state.dart';

/// 设备头像——列表里承担"一眼认出是哪台机器"的全部视觉信息。
///
/// 四层通道叠加，任何一层单独失效都还能认出来：
///  1. 底色：由 deviceId 稳定哈希得出。同机恒同色、跨端一致，
///     且不依赖用户起名质量（这是头像方案做不到的——同账号下
///     各设备头像会被同步成同一张，识别度为零）。
///  2. 首字：展示名（备注优先）的第一个字/字母。
///  3. 右下小徽：用途角色（常开主机/办公机/手机…），
///     未设置时回退到系统类型图标。
///  4. 外圈描边：在线状态（绿=在线，橙=能广播到但连不上，无=离线）。
/// 右上角再挂未读红点。
class DeviceAvatar extends StatelessWidget {
  final PeerView peer;
  final double size;

  /// 未读红点显示上限，超过显示 `99+`
  static const int badgeCap = 99;

  const DeviceAvatar({super.key, required this.peer, this.size = 40});

  @override
  Widget build(BuildContext context) {
    final online = peer.online;
    final fill = _deviceColor(peer.colorSeed, dimmed: !online);
    final ring = online
        ? const Color(0xFF2FB86A)
        : (peer.unreachable ? const Color(0xFFE8A33C) : null);

    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Center(
            child: Container(
              width: size - 6,
              height: size - 6,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: fill,
                border: ring == null
                    ? null
                    : Border.all(color: ring, width: 2),
              ),
              child: Center(
                child: Text(
                  peer.initial,
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: (size - 6) * 0.42,
                    fontWeight: FontWeight.w600,
                    height: 1.0,
                  ),
                ),
              ),
            ),
          ),
          // 右下角：用途角色角标
          Positioned(
            right: -1,
            bottom: -1,
            child: Container(
              padding: const EdgeInsets.all(1.5),
              decoration: const BoxDecoration(
                color: Colors.white,
                shape: BoxShape.circle,
              ),
              child: Icon(
                roleIcon(peer.role, peer.type),
                size: size * 0.3,
                color: online ? fill : Colors.black38,
              ),
            ),
          ),
          // 右上角：未读红点
          if (peer.unread > 0)
            Positioned(
              top: -2,
              right: -4,
              child: _UnreadBadge(count: peer.unread, cap: badgeCap),
            ),
        ],
      ),
    );
  }

  /// 角色 → 图标。未设置角色时按系统类型回退，保证任何设备都有角标。
  static IconData roleIcon(DeviceRole role, DeviceType type) {
    switch (role) {
      case DeviceRole.office:
        return Icons.desktop_windows;
      case DeviceRole.host:
        return Icons.dns;
      case DeviceRole.laptop:
        return Icons.laptop_mac;
      case DeviceRole.phone:
        return Icons.smartphone;
      case DeviceRole.tablet:
        return Icons.tablet_android;
      case DeviceRole.shared:
        return Icons.people_alt;
      case DeviceRole.unset:
        switch (type) {
          case DeviceType.windows:
            return Icons.computer;
          case DeviceType.android:
            return Icons.smartphone;
          case DeviceType.other:
            return Icons.devices_other;
        }
    }
  }
}

/// 未读数角标：红底白字，超过 cap 显示 `99+`
class _UnreadBadge extends StatelessWidget {
  final int count;
  final int cap;
  const _UnreadBadge({required this.count, required this.cap});

  @override
  Widget build(BuildContext context) {
    final text = count > cap ? '$cap+' : '$count';
    return Container(
      padding: EdgeInsets.symmetric(horizontal: text.length > 1 ? 4 : 0, vertical: 1),
      constraints: const BoxConstraints(minWidth: 16, minHeight: 16),
      decoration: BoxDecoration(
        color: const Color(0xFFE5484D),
        shape: text.length > 1 ? BoxShape.rectangle : BoxShape.circle,
        borderRadius: text.length > 1 ? BorderRadius.circular(9) : null,
        border: Border.all(color: Colors.white, width: 1.5),
      ),
      child: Text(
        text,
        textAlign: TextAlign.center,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 10,
          height: 1.1,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

/// 调色板：9 种色相跨度大、且都能托住白字的区分度。
/// 用固定表而不是 HSV 直接取模，避免哈希出灰蒙蒙或过暗的色块。
const List<Color> _devicePalette = [
  Color(0xFFE45C4A), // 砖红
  Color(0xFFE8963C), // 橙
  Color(0xFFC9A227), // 金
  Color(0xFF4FA36B), // 绿
  Color(0xFF2E9AA7), // 青
  Color(0xFF4A7BD0), // 蓝
  Color(0xFF7A5FD0), // 紫
  Color(0xFFC2569A), // 玫红
  Color(0xFF6B7A8F), // 灰蓝
];

/// 设备底色：种子取模选色；离线时向灰色插值压暗，
/// 让"离线"在整行变灰之外还有一层色彩线索。
Color _deviceColor(int seed, {bool dimmed = false}) {
  final base = _devicePalette[seed % _devicePalette.length];
  return dimmed ? Color.lerp(base, const Color(0xFFB9BCC2), 0.62)! : base;
}
