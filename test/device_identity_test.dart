import 'package:flutter_test/flutter_test.dart';

import 'package:crosslink/services/identity_service.dart';

void main() {
  test('设备 ID 派生：同一硬件标识恒定，不同标识不同', () {
    final a = DeviceBootstrap.deriveFromSeed('android:0123456789abcdef');
    final b = DeviceBootstrap.deriveFromSeed('android:0123456789abcdef');
    final c = DeviceBootstrap.deriveFromSeed('android:fedcba9876543210');
    expect(a, equals(b));
    expect(a, isNot(equals(c)));
    expect(a.length, equals(32));
    expect(a, matches(RegExp(r'^[0-9a-f]{32}$')));
  });

  test('平台前缀隔离：相同种子跨平台不碰撞', () {
    expect(DeviceBootstrap.deriveFromSeed('android:abc'),
        isNot(equals(DeviceBootstrap.deriveFromSeed('win:abc'))));
  });
}
