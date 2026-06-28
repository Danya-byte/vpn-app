import 'package:flutter_test/flutter_test.dart';
import 'package:vpn_app/core/desync_config.dart';

void main() {
  group('DesyncConfig.cleanHost', () {
    test('accepts bare hostnames', () {
      expect(DesyncConfig.cleanHost('youtube.com'), 'youtube.com');
      expect(DesyncConfig.cleanHost('sub.discord.com'), 'sub.discord.com');
      expect(DesyncConfig.cleanHost('rutracker.org'), 'rutracker.org');
    });

    test('normalises scheme / path / port / wildcard / case / trailing dot', () {
      expect(DesyncConfig.cleanHost('https://www.YouTube.com/watch?v=1'),
          'www.youtube.com');
      expect(DesyncConfig.cleanHost('discord.com:443'), 'discord.com');
      expect(DesyncConfig.cleanHost('*.linkedin.com'), 'linkedin.com');
      expect(DesyncConfig.cleanHost('proton.me.'), 'proton.me');
      expect(DesyncConfig.cleanHost('  X.com  '), 'x.com');
      // userinfo is stripped (user:pass@host) — was previously truncated to 'user'
      expect(DesyncConfig.cleanHost('https://user:pass@host.com/x'), 'host.com');
      expect(DesyncConfig.cleanHost('user@rutracker.org:443'), 'rutracker.org');
    });

    test('rejects junk, IPs, IPv6 literals and bare labels', () {
      expect(DesyncConfig.cleanHost(''), isNull);
      expect(DesyncConfig.cleanHost('localhost'), isNull);
      expect(DesyncConfig.cleanHost('1.2.3.4'), isNull); // numeric TLD
      expect(DesyncConfig.cleanHost('[2001:db8::1]:443'), isNull); // IPv6 literal
      expect(DesyncConfig.cleanHost('has space.com'), isNull);
      expect(DesyncConfig.cleanHost('-bad.com'), isNull);
      expect(DesyncConfig.cleanHost('a.b'), isNull); // 1-char TLD rejected
      expect(DesyncConfig.cleanHost('a.io'), 'a.io'); // 1-char label + real TLD
    });

    test('accepts punycode/IDN (xn--) labels and TLDs', () {
      expect(
          DesyncConfig.cleanHost('xn--80aswg.xn--p1ai'), 'xn--80aswg.xn--p1ai');
      expect(DesyncConfig.cleanHost('xn--90a.com'), 'xn--90a.com');
      expect(DesyncConfig.cleanHost('HTTPS://xn--90A.com/x'), 'xn--90a.com');
      // raw cyrillic (not punycode) is rejected — must be supplied as xn--
      expect(DesyncConfig.cleanHost('пример.рф'), isNull);
    });
  });

  group('DesyncConfig.hostlistContent', () {
    test('de-dupes, lower-cases, sorts, one per line, trailing newline', () {
      final out = DesyncConfig.hostlistContent(
          ['B.com', 'a.com', 'b.com', 'A.com', 'junk', '']);
      expect(out, 'a.com\nb.com\n');
    });

    test('empty / all-invalid yields a single newline (never empty file)', () {
      expect(DesyncConfig.hostlistContent(const []), '\n');
      expect(DesyncConfig.hostlistContent(['nope', '...']), '\n');
    });

    test('default hosts are all valid + survive the cleaner', () {
      final out = DesyncConfig.hostlistContent(DesyncConfig.defaultHosts);
      final lines = out.trim().split('\n');
      // every default host is a valid hostname → none dropped (after de-dupe)
      expect(lines.toSet().length, lines.length); // unique
      expect(lines, contains('linkedin.com'));
      expect(lines, contains('rutracker.org'));
      expect(lines, everyElement(isNot(contains('/'))));
    });
  });

  group('DesyncConfig.winwsArgs', () {
    test('TCP-only by default (no quic payload): NO udp/QUIC block', () {
      final a = DesyncConfig.winwsArgs(hostlistPath: r'C:\run\hl.txt');
      // global WinDivert window present, TCP only
      expect(a, contains('--wf-tcp=80,443'));
      expect(a, isNot(contains('--wf-udp=443'))); // no payload → no UDP block
      expect(a, isNot(contains('--filter-udp=443')));
      expect(a, isNot(contains('--dpi-desync-repeats=6')));
      // both TCP ports have their own filter block
      expect(a, contains('--filter-tcp=443'));
      expect(a, contains('--filter-tcp=80'));
      // the default (RF-2026, live-verified) method flags are present:
      // fake + multidisorder + datanoack at three SNI-targeted cut points, with a
      // padded Russian-gov-SNI decoy (survives a stateful/whitelist DPI).
      expect(a, contains('--dpi-desync=fake,multidisorder'));
      expect(a, contains('--dpi-desync-split-pos=1,midsld,sniext+1'));
      expect(a, contains('--dpi-desync-fooling=datanoack'));
      expect(a, contains('--dpi-desync-fake-tls-mod=padencap,sni=gosuslugi.ru'));
      // 2 TCP blocks → 2 hostlist refs, 1 separator
      expect(a.where((x) => x == r'--hostlist=C:\run\hl.txt').length, 2);
      expect(a.where((x) => x == '--new').length, 1);
    });

    test('a quic payload enables the UDP/443 (HTTP-3) desync block', () {
      final a = DesyncConfig.winwsArgs(
          hostlistPath: '/t/hl', quicPayloadPath: r'C:\core\quic_initial.bin');
      expect(a, contains('--wf-udp=443'));
      expect(a, contains('--filter-udp=443'));
      expect(a, contains('--dpi-desync=fake'));
      expect(a, contains(r'--dpi-desync-fake-quic=C:\core\quic_initial.bin'));
      expect(a, contains('--dpi-desync-repeats=6'));
      // 3 blocks (TCP443 + TCP80 + UDP443) → 3 hostlist refs, 2 separators
      expect(a.where((x) => x == '--hostlist=/t/hl').length, 3);
      expect(a.where((x) => x == '--new').length, 2);
    });

    test('unknown strategy falls back to the default method', () {
      final a = DesyncConfig.winwsArgs(hostlistPath: '/t/hl', strategy: 'bogus');
      expect(a, contains('--dpi-desync=fake,multidisorder'));
    });

    test('split strategy emits its own flags (datanoack, no fake decoy)', () {
      final a =
          DesyncConfig.winwsArgs(hostlistPath: '/t/hl', strategy: 'split');
      expect(a, contains('--dpi-desync=split2'));
      expect(a, contains('--dpi-desync-split-pos=sniext+1'));
      expect(a, contains('--dpi-desync-fooling=datanoack'));
      expect(a, isNot(contains('--dpi-desync-fooling=md5sig')));
    });

    test('hostlist path with spaces stays a single arg element', () {
      final a =
          DesyncConfig.winwsArgs(hostlistPath: r'C:\Users\a b\run\hl.txt');
      expect(a, contains(r'--hostlist=C:\Users\a b\run\hl.txt'));
    });
  });

  group('DesyncConfig.winwsArgs — SNI-only output (no Telegram profile)', () {
    test('default capture window is 80,443 with no STUN/ipset', () {
      final plain = DesyncConfig.winwsArgs(hostlistPath: '/t/hl');
      expect(plain, contains('--wf-tcp=80,443'));
      expect(plain, isNot(contains('--filter-l7=stun')));
      expect(plain.any((x) => x.startsWith('--ipset=')), isFalse);
    });
  });

  group('DesyncConfig.isValidStrategy', () {
    test('known + unknown', () {
      expect(DesyncConfig.isValidStrategy('fake_split'), isTrue);
      expect(DesyncConfig.isValidStrategy('fake_disorder'), isTrue);
      expect(DesyncConfig.isValidStrategy('split'), isTrue);
      expect(DesyncConfig.isValidStrategy('nope'), isFalse);
      expect(DesyncConfig.isValidStrategy(DesyncConfig.defaultStrategy), isTrue);
    });
  });
}
