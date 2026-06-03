import 'package:flutter_test/flutter_test.dart';
import 'package:vpn_app/core/sub_info.dart';

void main() {
  test('parses a standard Subscription-Userinfo header', () {
    final i = SubInfo.parse(
        'upload=100; download=200; total=1000; expire=1767139200')!;
    expect(i.used, 300);
    expect(i.total, 1000);
    expect(i.remaining, 700);
    expect(i.hasTraffic, isTrue);
    expect(i.hasExpiry, isTrue);
  });

  test('handles partial / junk / empty headers', () {
    expect(SubInfo.parse(null), isNull);
    expect(SubInfo.parse(''), isNull);
    expect(SubInfo.parse('garbage'), isNull);
    final t = SubInfo.parse('total=500')!;
    expect(t.total, 500);
    expect(t.used, 0);
    expect(t.hasExpiry, isFalse);
  });

  test('daysLeft is relative to a passed-in now (and can be negative)', () {
    final expire = DateTime(2026, 1, 11).millisecondsSinceEpoch ~/ 1000;
    final i = SubInfo(expire: expire);
    expect(i.daysLeft(DateTime(2026, 1, 1)), 10);
    expect(i.daysLeft(DateTime(2026, 1, 15))! < 0, isTrue);
  });

  test('round-trips through json', () {
    const i = SubInfo(upload: 1, download: 2, total: 3, expire: 4);
    final j = SubInfo.fromJson(i.toJson());
    expect(j.used, 3);
    expect(j.total, 3);
    expect(j.expire, 4);
  });
}
