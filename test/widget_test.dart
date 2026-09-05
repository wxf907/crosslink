import 'package:flutter_test/flutter_test.dart';

import 'package:crosslink/models/identity.dart';

void main() {
  test('groupId 由账号密码稳定派生，且相同凭证一致', () {
    final a = Identity.deriveGroupId('alice', '123456');
    final b = Identity.deriveGroupId('alice', '123456');
    final c = Identity.deriveGroupId('alice', '654321');
    expect(a, equals(b));
    expect(a, isNot(equals(c)));
    expect(a.length, equals(64)); // sha256 hex
  });
}
