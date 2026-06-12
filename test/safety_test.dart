import 'package:flutter_test/flutter_test.dart';
import 'package:vpn_app/core/lifecycle.dart';
import 'package:vpn_app/core/singbox_config.dart';

/// Safety-critical contracts the audit flagged as untested (M1/M2/M3 + H1):
/// the kill-switch fail-closed exit decision, the fence permit-list, and the
/// leak-shape of the generated configs. All PURE — no network, no core.
void main() {
  group('decideExit — fail-closed contract (M2)', () {
    ExitDecision d({
      bool restarting = false,
      bool stopping = false,
      bool autoReconnect = true,
      bool portConflict = false,
      bool wgDead = false,
      int exitRetries = 1,
    }) =>
        decideExit(
          restarting: restarting,
          stopping: stopping,
          autoReconnect: autoReconnect,
          portConflict: portConflict,
          wgDead: wgDead,
          exitRetries: exitRetries,
        );

    test('unexpected death mid-session FAILS CLOSED (no proxy restore, fence up)',
        () {
      final r = d(exitRetries: 1);
      expect(r.outcome, ExitOutcome.reconnect);
      expect(r.failsClosed, isTrue);
      expect(r.restoreProxy, isFalse);
      expect(r.disengageFence, isFalse);
    });

    test('a deliberate restart/swap keeps it CLOSED', () {
      final r = d(restarting: true);
      expect(r.outcome, ExitOutcome.restartingKeepClosed);
      expect(r.failsClosed, isTrue);
    });

    test('a deliberate stop restores the proxy + drops the fence', () {
      final r = d(stopping: true);
      expect(r.outcome, ExitOutcome.stopRestore);
      expect(r.restoreProxy, isTrue);
      expect(r.disengageFence, isTrue);
    });

    test('autoReconnect off behaves like a deliberate stop', () {
      expect(d(autoReconnect: false).outcome, ExitOutcome.stopRestore);
    });

    test('restarting WINS over every terminal flag (checked first)', () {
      final r = d(restarting: true, portConflict: true, wgDead: true,
          exitRetries: 99);
      expect(r.outcome, ExitOutcome.restartingKeepClosed);
    });

    test('port conflict + WG-dead are terminal (restore + fence off)', () {
      expect(d(portConflict: true).outcome, ExitOutcome.portInUse);
      expect(d(wgDead: true).outcome, ExitOutcome.wireguardDead);
      expect(d(portConflict: true).restoreProxy, isTrue);
      expect(d(wgDead: true).disengageFence, isTrue);
    });

    test('gives up only AFTER the retry ceiling, reconnects below it', () {
      expect(d(exitRetries: 6).outcome, ExitOutcome.reconnect); // 6 == max
      expect(d(exitRetries: 7).outcome, ExitOutcome.gaveUp); // > max
      expect(d(exitRetries: 6).failsClosed, isTrue); // still closed while retrying
    });

    test('fence-INSTALL-fail BLOCKS: refuse + clear error, restore (anti-lockout)',
        () {
      final r = decideExit(
        restarting: false,
        stopping: false,
        autoReconnect: false, // start() sets this false right before the kill
        portConflict: false,
        wgDead: false,
        exitRetries: 1,
        fenceFailed: true,
      );
      expect(r.outcome, ExitOutcome.killSwitchFailed);
      expect(r.restoreProxy, isTrue); // fence never installed → nothing to keep closed
      expect(r.failsClosed, isFalse);
    });

    test('fenceFailed WINS over restarting (never silently relaunch unprotected)',
        () {
      expect(
        decideExit(
          restarting: true,
          stopping: false,
          autoReconnect: true,
          portConflict: false,
          wgDead: false,
          exitRetries: 1,
          fenceFailed: true,
        ).outcome,
        ExitOutcome.killSwitchFailed,
      );
    });

    test('give-up with the kill-switch ON stays FAIL-CLOSED (M5)', () {
      final fenced = decideExit(
        restarting: false,
        stopping: false,
        autoReconnect: true,
        portConflict: false,
        wgDead: false,
        exitRetries: 7,
        killSwitchActive: true,
      );
      expect(fenced.outcome, ExitOutcome.gaveUpFenced);
      expect(fenced.failsClosed, isTrue); // fence stays up, proxy NOT restored
      // Without the kill-switch, give-up restores connectivity (anti-lockout).
      expect(d(exitRetries: 7).outcome, ExitOutcome.gaveUp);
      expect(d(exitRetries: 7).failsClosed, isFalse);
    });
  });

  group('resume / network-change gates (M4 — never restart a healthy tunnel)',
      () {
    test('resume probe only when on + not mid-restart/adapt', () {
      expect(
          shouldProbeOnResume(isOn: true, restarting: false, adapting: false),
          isTrue);
      expect(
          shouldProbeOnResume(isOn: false, restarting: false, adapting: false),
          isFalse); // not connected → nothing to probe
      expect(
          shouldProbeOnResume(isOn: true, restarting: true, adapting: false),
          isFalse); // a swap owns the relaunch
      expect(
          shouldProbeOnResume(isOn: true, restarting: false, adapting: true),
          isFalse); // auto-adapt owns it
    });

    test('network-change acts only while connected + not swapping', () {
      expect(shouldActOnNetworkChange(isOn: true, restarting: false), isTrue);
      expect(shouldActOnNetworkChange(isOn: false, restarting: false), isFalse);
      expect(shouldActOnNetworkChange(isOn: true, restarting: true), isFalse);
    });
  });

  group('classifyCoreLog — pure log→signal (decoupled from ingestion)', () {
    test('recognises a port-bind conflict', () {
      expect(
          classifyCoreLog('FATAL bind: address already in use'),
          CoreLogSignal.portConflict);
      expect(
          classifyCoreLog(
              'bind: Only one usage of each socket address is normally permitted'),
          CoreLogSignal.portConflict);
    });

    test('recognises WireGuard handshake fail vs alive', () {
      expect(classifyCoreLog('peer(x) handshake did not complete after 5s'),
          CoreLogSignal.wgHandshakeFail);
      expect(classifyCoreLog('Receiving handshake response from peer'),
          CoreLogSignal.wgHandshakeOk);
      expect(classifyCoreLog('Sending keepalive packet'),
          CoreLogSignal.wgHandshakeOk);
    });

    test('an ordinary line is no signal', () {
      expect(classifyCoreLog('inbound/mixed: tcp connection from ...'),
          CoreLogSignal.none);
    });
  });

  group('fencePermitPaths — every dialing core is permitted (H1)', () {
    test('includes the xray bridge when xray is available', () {
      expect(fencePermitPaths('sing-box.exe', 'xray.exe', xrayAvailable: true),
          ['sing-box.exe', 'xray.exe']);
    });

    test('omits xray when unavailable / path missing', () {
      expect(fencePermitPaths('sing-box.exe', 'xray.exe', xrayAvailable: false),
          ['sing-box.exe']);
      expect(fencePermitPaths('sing-box.exe', null, xrayAvailable: true),
          ['sing-box.exe']);
      expect(fencePermitPaths('sing-box.exe', '', xrayAvailable: true),
          ['sing-box.exe']);
    });
  });

  group('desyncOnly — no-server leak shape (M3)', () {
    final cfg = SingBoxConfig.desyncOnly();
    final rules = ((cfg['route'] as Map)['rules'] as List).cast<Map>();

    test('sniff then hijack-dns lead (DNS resolved before anything routes)', () {
      expect(rules[0]['action'], 'sniff');
      expect(rules[1]['action'], 'hijack-dns');
    });

    test('throttled domains: QUIC (UDP/443) is REJECTED so DPI-frag applies', () {
      final reject = rules.firstWhere((r) =>
          r['action'] == 'reject' && r['network'] == 'udp' && r['port'] == 443);
      expect((reject['domain_suffix'] as List), contains('youtube.com'));
    });

    test('throttled domains go DIRECT with tls_fragment on', () {
      final frag = rules.firstWhere(
          (r) => r['action'] == 'route' && r['tls_fragment'] == true);
      expect(frag['outbound'], 'direct');
      expect((frag['domain_suffix'] as List), contains('discord.com'));
    });

    test('everything else is direct (no server)', () {
      expect((cfg['route'] as Map)['final'], 'direct');
    });
  });

  group('withTun — leak-shape of TUN routing (M3)', () {
    Map<String, dynamic> base() => {
          'outbounds': [
            {'type': 'vless', 'tag': 'proxy', 'server': '1.2.3.4'},
            {'type': 'direct', 'tag': 'direct'},
          ],
          'route': {
            'rules': [
              {'action': 'sniff'},
              {'protocol': 'dns', 'action': 'hijack-dns'},
            ],
            'final': 'proxy',
          },
        };

    test('pins interface_name tun0 so the WFP fence can find its LUID', () {
      final cfg = SingBoxConfig.withTun(base());
      final tun = (cfg['inbounds'] as List)
          .cast<Map>()
          .firstWhere((i) => i['type'] == 'tun');
      expect(tun['interface_name'], 'tun0');
    });

    test('a force-through-VPN app rule sits AFTER hijack-dns (DNS first)', () {
      final cfg = SingBoxConfig.withTun(base(), forceApps: ['discord.exe']);
      final rules = ((cfg['route'] as Map)['rules'] as List).cast<Map>();
      final hijackAt = rules.indexWhere((r) => r['action'] == 'hijack-dns');
      // The probe rule is process-scoped now too (to vpn_app.exe), so locate the
      // discord rule specifically rather than the first process_name rule.
      final appAt = rules.indexWhere(
          (r) => (r['process_name'] as List?)?.contains('discord.exe') ?? false);
      expect(hijackAt, isNonNegative);
      expect(appAt, greaterThan(hijackAt),
          reason: 'a process rule before hijack-dns kills the app\'s DNS');
      final appRule = rules[appAt];
      expect((appRule['process_name'] as List), contains('discord.exe'));
      expect(appRule['outbound'], 'proxy'); // forced THROUGH the VPN, not direct
    });

    test('a split-tunnel app routes DIRECT, still after hijack-dns', () {
      final cfg = SingBoxConfig.withTun(base(), splitApps: ['game.exe']);
      final rules = ((cfg['route'] as Map)['rules'] as List).cast<Map>();
      final hijackAt = rules.indexWhere((r) => r['action'] == 'hijack-dns');
      final appAt = rules.indexWhere(
          (r) => (r['process_name'] as List?)?.contains('game.exe') ?? false);
      expect(appAt, greaterThan(hijackAt));
      expect(rules[appAt]['outbound'], 'direct');
    });

    test('captures IPv6 (ULA) so v6 cannot leak out the physical NIC', () {
      final cfg = SingBoxConfig.withTun(base());
      final tun = (cfg['inbounds'] as List)
          .cast<Map>()
          .firstWhere((i) => i['type'] == 'tun');
      final addrs = (tun['address'] as List).cast<String>();
      expect(addrs.any((a) => a.contains(':')), isTrue,
          reason: 'an IPv6 address makes auto_route install a ::/0 route, so '
              'system IPv6 is pulled into the tunnel instead of going direct');
      expect(addrs.any((a) => a.startsWith('172.')), isTrue,
          reason: 'the IPv4 TUN range is still present');
    });

    test('routes the whitelist-probe IPs DIRECT, after hijack-dns (#3)', () {
      // In TUN, auto_route captures the controller's own raw foreign dial too, so
      // a dark tunnel would eat the probe and false-latch "whitelist mode". The
      // probe IPs must be pinned DIRECT so the dial measures the PHYSICAL uplink.
      final cfg = SingBoxConfig.withTun(base());
      final rules = ((cfg['route'] as Map)['rules'] as List).cast<Map>();
      final hijackAt = rules.indexWhere((r) => r['action'] == 'hijack-dns');
      final probeAt = rules.indexWhere((r) {
        final ips = r['ip_cidr'];
        return ips is List && ips.contains('8.8.8.8/32');
      });
      expect(probeAt, greaterThan(hijackAt),
          reason: 'probe rule must sit after hijack-dns (so DNS still works) '
              'and before the geo/final rules (so it wins)');
      final probe = rules[probeAt];
      expect(probe['outbound'], 'direct');
      for (final ip in SingBoxConfig.foreignProbeIps) {
        expect((probe['ip_cidr'] as List), contains('$ip/32'));
      }
      // SCOPED to our OWN process — otherwise EVERY app's traffic to these public
      // DNS IPs (a DoH browser pointed at 8.8.8.8) would egress DIRECT, leaking the
      // real IP past the tunnel in TUN. Only the watchdog's own probe may escape.
      expect(probe['process_name'], contains('vpn_app.exe'),
          reason: 'probe-direct must be limited to vpn_app.exe, not all traffic');
    });

    test('still routes probe IPs direct even when the config lacks a direct '
        'outbound (creates one)', () {
      final noDirect = {
        'outbounds': [
          {'type': 'vless', 'tag': 'proxy', 'server': '1.2.3.4'},
        ],
        'route': {
          'rules': [
            {'action': 'sniff'},
            {'protocol': 'dns', 'action': 'hijack-dns'},
          ],
          'final': 'proxy',
        },
      };
      final cfg = SingBoxConfig.withTun(noDirect);
      final outs = (cfg['outbounds'] as List).cast<Map>();
      expect(outs.any((o) => o['type'] == 'direct'), isTrue,
          reason: 'a direct outbound must exist for the probe rule to reference');
      final rules = ((cfg['route'] as Map)['rules'] as List).cast<Map>();
      expect(
          rules.any((r) =>
              r['ip_cidr'] is List &&
              (r['ip_cidr'] as List).contains('9.9.9.9/32') &&
              r['outbound'] == 'direct'),
          isTrue);
    });
  });
}
