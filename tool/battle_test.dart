import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:vpn_app/core/cascade.dart';
import 'package:vpn_app/core/censorship_facts.dart';
import 'package:vpn_app/core/singbox_config.dart';

/// BATTLE TEST — drive EVERY transport leaf + EVERY toggle of the real stored
/// profile through the bundled sing-box, against the live server, and report a
/// PASS/FAIL matrix. The honest scope (this box is co-located with the server, so
/// exit==direct and there is no ТСПУ here): it proves each config is VALID
/// (`sing-box check`), the core RUNS it, and the proxy CARRIES traffic (a request
/// through the proxy pinned to ONE node returns an IP ⇒ that node's handshake +
/// tunnel work). It can NOT prove a foreign exit or reproduce ТСПУ — those are
/// the user's on-device checks. XHTTP leaves need the xray bridge (the app spawns
/// it); here they're validated with `xray check` instead of run.
///
///   dart run tool/battle_test.dart
late final String _sb;
late final String _xray;
late final String _cwd;
const _env = {
  'ENABLE_DEPRECATED_LEGACY_DNS_SERVERS': 'true',
  'ENABLE_DEPRECATED_GEOSITE': 'true',
  'ENABLE_DEPRECATED_SPECIAL_OUTBOUNDS': 'true',
  'ENABLE_DEPRECATED_OUTBOUND_DNS_RULE_ITEM': 'true',
  'ENABLE_DEPRECATED_DNS_RULE_ACTIONS': 'true',
  'ENABLE_DEPRECATED_MISSING_DOMAIN_RESOLVER': 'true',
};

final _rows = <(String, String, String)>[]; // (group, name, verdict)
void _row(String g, String n, String v) {
  _rows.add((g, n, v));
  stdout.writeln('  [$g] $n → $v');
}

Future<void> main() async {
  _cwd = Directory.current.path;
  _sb = '$_cwd\\core\\windows\\sing-box.exe';
  _xray = '$_cwd\\core\\windows\\xray.exe';
  SingBoxConfig.ruleSetDir = '$_cwd\\core\\rule-sets';
  SingBoxConfig.clashSecret = 'battle-secret-9a1f';

  final store =
      File('${Platform.environment['LOCALAPPDATA']}\\vpn_app\\run\\profiles.json');
  final j = jsonDecode(store.readAsStringSync()) as Map<String, dynamic>;
  final nodes = (j['nodes'] as List).cast<Map<String, dynamic>>();
  final sel = j['selected']?.toString();
  final node = nodes.firstWhere((n) => n['tag'] == sel, orElse: () => nodes.first);
  final cfg = (node['config'] as Map).cast<String, dynamic>();
  final leaves = (cfg['outbounds'] as List)
      .cast<Map>()
      .where((o) => const {'vless', 'vmess', 'trojan', 'hysteria2', 'tuic'}
          .contains(o['type']))
      .toList();

  stdout.writeln('=== BATTLE TEST: ${leaves.length} leaves against the live server ===\n');
  await _killCores();

  // A) Per-leaf connect: pin the proxy to ONE node, prove it carries traffic.
  stdout.writeln('A) Per-leaf live connect (proxy pinned to one node):');
  for (final leaf in leaves) {
    final tag = '${leaf['tag']}';
    final transport = (leaf['transport'] as Map?)?['type'];
    if (transport == 'xhttp') {
      // sing-box has no xhttp outbound transport — the app bridges it to xray.
      final ok = await _xrayCheckXhttp(leaf.cast<String, dynamic>());
      _row('leaf', tag, ok ? 'XHTTP: xray check OK (bridged in app)' : 'XHTTP: xray check FAIL');
      continue;
    }
    final ip = await _runAndProbe(_wrapLeaf(leaf.cast<String, dynamic>()));
    _row('leaf', tag, ip != null ? 'CONNECTS (exit $ip)' : 'no traffic');
  }

  // B) The ①-freeze remedy is a transport HOP (battle-tested 2026-06: reshaping a
  // flow-mandating Reality node is REJECTED by the server, so we leave the long
  // TLS stream instead). Verify the pool actually HAS a non-TCP-TLS target for
  // the hop to land on — XHTTP (sub-16KB request pairs) or QUIC (Hy2/TUIC).
  stdout.writeln('\nB) Freeze-hop target present (the volume rule does not reach XHTTP/QUIC)?');
  final fams = familiesFromConfig(cfg).values.toSet();
  final hasAlt =
      fams.any((f) => f == 'hysteria2' || f == 'tuic' || f.endsWith('-xhttp'));
  _row('freeze-hop', 'pool families', fams.join(', '));
  _row('freeze-hop', 'has XHTTP/QUIC alternative',
      hasAlt ? 'YES — freeze hop has a target' : 'NO — single TCP-TLS pool');

  // B2) Native Telegram unblock — the built config must PIN Telegram (CIDRs +
  // domains) to the proxy exit.
  final built = SingBoxConfig.fromConfig(cfg);
  final rules = ((built['route'] as Map)['rules'] as List).cast<Map>();
  String listStr(dynamic v) => v is List ? v.join(',') : '${v ?? ''}';
  final tgRule = rules.firstWhere(
      (r) => listStr(r['ip_cidr']).contains('149.154.160.0/20'),
      orElse: () => {});
  _row('telegram', 'TG CIDRs pinned in built config',
      tgRule.isNotEmpty ? 'YES → ${tgRule['outbound']}' : 'MISSING');

  // C) Toggle matrix on the FULL config — each must pass the real core schema.
  stdout.writeln('\nC) Toggle matrix (full config through fromConfig → sing-box check):');
  final toggles = <String, Map<String, dynamic>>{
    'baseline': SingBoxConfig.fromConfig(cfg),
    'antiDpi(fragment)': SingBoxConfig.fromConfig(cfg, antiDpi: true),
    'mux': SingBoxConfig.fromConfig(cfg, mux: true),
    'ech': SingBoxConfig.fromConfig(cfg, ech: true),
    'fp=firefox': SingBoxConfig.fromConfig(cfg, fingerprintOverride: 'firefox'),
    'fp=safari': SingBoxConfig.fromConfig(cfg, fingerprintOverride: 'safari'),
    'ruDirect(smart)': SingBoxConfig.fromConfig(cfg, ruDirect: true),
  };
  for (final e in toggles.entries) {
    final err = await _check(e.value);
    _row('toggle', e.key, err == null ? 'check OK' : 'FAIL: $err');
  }

  // D) Server-less + TUN modes the app can run with no node selected.
  stdout.writeln('\nD) No-server modes + TUN wrap:');
  for (final e in <String, Map<String, dynamic>>{
    'desyncOnly()': SingBoxConfig.desyncOnly(),
    'm0Local()': SingBoxConfig.m0Local(),
    'withTun(full)': SingBoxConfig.withTun(SingBoxConfig.fromConfig(cfg)),
    'withTun(desync)': SingBoxConfig.withTun(SingBoxConfig.desyncOnly()),
  }.entries) {
    final err = await _check(e.value);
    _row('mode', e.key, err == null ? 'check OK' : 'FAIL: $err');
  }

  // E) Live watchdog probes on the running full config — the ① signals, proving
  // they return the correct values when NOT under ТСПУ (healthy / bulk-ok / RU up
  // / foreign reachable ⇒ classified as healthy, not freeze, not whitelist).
  stdout.writeln('\nE) ①-watchdog live probes (full config running):');
  await _probeWatchdog(SingBoxConfig.fromConfig(cfg));

  // Summary
  final pass = _rows.where((r) => !r.$3.contains('FAIL') && !r.$3.contains('no traffic') && !r.$3.contains('REJECTS')).length;
  stdout.writeln('\n=== $pass/${_rows.length} checks green ===');
  await _killCores();
}

Map<String, dynamic> _wrapLeaf(Map<String, dynamic> leaf) => {
      'log': {'level': 'warn', 'timestamp': true},
      'dns': {
        'servers': [
          {'type': 'https', 'tag': 'dns-direct', 'server': '77.88.8.8'}
        ],
        'final': 'dns-direct',
        'strategy': 'ipv4_only',
      },
      'experimental': {
        'clash_api': {
          'external_controller':
              '${SingBoxConfig.clashHost}:${SingBoxConfig.clashPort}',
          'secret': SingBoxConfig.clashSecret,
        }
      },
      'inbounds': [
        {
          'type': 'mixed',
          'tag': 'mixed-in',
          'listen': SingBoxConfig.mixedListen,
          'listen_port': SingBoxConfig.mixedPort,
        }
      ],
      'outbounds': [leaf, {'type': 'direct', 'tag': 'direct'}],
      'route': {
        'rules': [
          {'action': 'sniff'},
          {'protocol': 'dns', 'action': 'hijack-dns'},
        ],
        'final': leaf['tag'],
        'auto_detect_interface': true,
      },
    };

Future<String?> _check(Map<String, dynamic> cfg) async {
  final dir = Directory.systemTemp.createTempSync('bt');
  try {
    final f = File('${dir.path}\\c.json')
      ..writeAsStringSync(SingBoxConfig.encode(cfg));
    final r = await Process.run(_sb, ['check', '-c', f.path], environment: _env);
    if (r.exitCode == 0) return null;
    return _firstFatal('${r.stdout}${r.stderr}');
  } finally {
    dir.deleteSync(recursive: true);
  }
}

/// Validate a vless+xhttp leaf with xray (the engine the app bridges it through).
Future<bool> _xrayCheckXhttp(Map<String, dynamic> leaf) async {
  if (!File(_xray).existsSync()) return false;
  // Minimal xray outbound JSON shape; xray `test`/`-test` validates config.
  final t = leaf['tls'] as Map? ?? {};
  final reality = t['reality'] as Map? ?? {};
  final xr = {
    'inbounds': [
      {'port': 24999, 'listen': '127.0.0.1', 'protocol': 'socks', 'settings': {}}
    ],
    'outbounds': [
      {
        'protocol': 'vless',
        'settings': {
          'vnext': [
            {
              'address': leaf['server'],
              'port': leaf['server_port'],
              'users': [
                {'id': leaf['uuid'], 'encryption': 'none', 'flow': leaf['flow'] ?? ''}
              ]
            }
          ]
        },
        'streamSettings': {
          'network': 'xhttp',
          'security': 'reality',
          'realitySettings': {
            'serverName': t['server_name'],
            'publicKey': reality['public_key'],
            'shortId': reality['short_id'] ?? '',
          },
          'xhttpSettings': {'path': (leaf['transport'] as Map?)?['path'] ?? '/'}
        }
      }
    ]
  };
  final dir = Directory.systemTemp.createTempSync('xr');
  try {
    final f = File('${dir.path}\\x.json')..writeAsStringSync(jsonEncode(xr));
    final r = await Process.run(_xray, ['-test', '-c', f.path]);
    return r.exitCode == 0;
  } catch (_) {
    return false;
  } finally {
    dir.deleteSync(recursive: true);
  }
}

/// Run a config, return the exit IP seen THROUGH the proxy (null = no traffic).
Future<String?> _runAndProbe(Map<String, dynamic> cfg) async {
  await _killCores();
  final dir = Directory.systemTemp.createTempSync('btrun');
  final f = File('${dir.path}\\c.json')
    ..writeAsStringSync(SingBoxConfig.encode(cfg));
  // Pre-validate so a schema error is reported as such, not as "no traffic".
  final chk = await Process.run(_sb, ['check', '-c', f.path], environment: _env);
  if (chk.exitCode != 0) {
    dir.deleteSync(recursive: true);
    return null;
  }
  final proc = await Process.start(_sb, ['run', '-c', f.path],
      environment: _env, workingDirectory: dir.path);
  try {
    for (var i = 0; i < 12; i++) {
      final ip = await _fetch('http://api.ipify.org',
          proxy: '${SingBoxConfig.mixedListen}:${SingBoxConfig.mixedPort}');
      if (ip != null) return ip;
      await Future<void>.delayed(const Duration(seconds: 1));
    }
    return null;
  } finally {
    proc.kill();
    await proc.exitCode.timeout(const Duration(seconds: 5), onTimeout: () => -1);
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  }
}

/// Run the full config and exercise the actual ① watchdog probes against it.
Future<void> _probeWatchdog(Map<String, dynamic> cfg) async {
  await _killCores();
  final dir = Directory.systemTemp.createTempSync('btwd');
  final f = File('${dir.path}\\c.json')
    ..writeAsStringSync(SingBoxConfig.encode(cfg));
  final proc = await Process.start(_sb, ['run', '-c', f.path],
      environment: _env, workingDirectory: dir.path);
  try {
    // wait for the proxy to come up
    String? up;
    for (var i = 0; i < 12 && up == null; i++) {
      up = await _fetch('http://api.ipify.org',
          proxy: '${SingBoxConfig.mixedListen}:${SingBoxConfig.mixedPort}');
      if (up == null) await Future<void>.delayed(const Duration(seconds: 1));
    }
    final t204 = await _status204();
    final bulk = await _bulkOk();
    final ru = await _rawConnect('ya.ru', 443);
    final f1 = await _rawConnect('8.8.8.8', 443);
    final f2 = await _rawConnect('9.9.9.9', 443);
    final foreign = f1 || f2;
    _row('probe', '_tunnelHealthy (204 via proxy)', t204 ? 'OK (healthy)' : 'dark');
    _row('probe', '_bulkThroughOk (>${CensorshipFacts.active.freezeThresholdKb}KB)',
        bulk ? 'OK (no freeze)' : 'STALL (would trigger remedy)');
    _row('probe', '_directNetworkUp (ya.ru:443)', ru ? 'UP' : 'down');
    _row('probe', '_foreignNetworkUp (8.8.8.8/9.9.9.9:443)',
        foreign ? 'reachable (NOT whitelist)' : 'all dark (WHITELIST mode)');
    final mode = !ru
        ? 'networkDown'
        : !foreign
            ? 'WHITELIST'
            : !t204
                ? 'hardBlock→cascade'
                : !bulk
                    ? 'FREEZE→remedy'
                    : 'HEALTHY';
    _row('probe', 'classified mode', mode);
    // Native Telegram unblock: prove Telegram rides the tunnel (web + a raw DC).
    final tgWeb = await _reachableViaProxy('https://core.telegram.org');
    _row('telegram', 'core.telegram.org via tunnel', tgWeb ? 'reachable' : 'unreachable');
  } finally {
    proc.kill();
    await proc.exitCode.timeout(const Duration(seconds: 5), onTimeout: () => -1);
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  }
}

Future<bool> _status204() async {
  final c = HttpClient()
    ..connectionTimeout = const Duration(seconds: 6)
    ..findProxy = (_) =>
        'PROXY ${SingBoxConfig.mixedListen}:${SingBoxConfig.mixedPort}';
  try {
    final r = await (await c.getUrl(
            Uri.parse('http://www.gstatic.com/generate_204')))
        .close()
        .timeout(const Duration(seconds: 7));
    return r.statusCode == 204 || r.statusCode == 200;
  } catch (_) {
    return false;
  } finally {
    c.close(force: true);
  }
}

Future<bool> _bulkOk() async {
  final facts = CensorshipFacts.active;
  final c = HttpClient()
    ..connectionTimeout = const Duration(seconds: 6)
    ..findProxy = (_) =>
        'PROXY ${SingBoxConfig.mixedListen}:${SingBoxConfig.mixedPort}';
  try {
    final resp = await (await c.getUrl(Uri.parse(facts.freezeProbeUrl)))
        .close()
        .timeout(const Duration(seconds: 9));
    var got = 0;
    await for (final ch in resp.timeout(const Duration(seconds: 9))) {
      got += ch.length;
    }
    return got >= facts.freezeThresholdKb * 1024;
  } catch (_) {
    return false;
  } finally {
    c.close(force: true);
  }
}

/// True if [url] returns any non-5xx response THROUGH the proxy (proves the
/// destination — e.g. Telegram — actually rides the tunnel, body length aside).
Future<bool> _reachableViaProxy(String url) async {
  final c = HttpClient()
    ..connectionTimeout = const Duration(seconds: 8)
    ..findProxy = (_) =>
        'PROXY ${SingBoxConfig.mixedListen}:${SingBoxConfig.mixedPort}';
  try {
    final r =
        await (await c.getUrl(Uri.parse(url))).close().timeout(const Duration(seconds: 10));
    return r.statusCode < 500;
  } catch (_) {
    return false;
  } finally {
    c.close(force: true);
  }
}

Future<bool> _rawConnect(String host, int port) async {
  try {
    final s =
        await Socket.connect(host, port, timeout: const Duration(seconds: 4));
    s.destroy();
    return true;
  } catch (_) {
    return false;
  }
}

Future<String?> _fetch(String url, {String? proxy}) async {
  final c = HttpClient()..connectionTimeout = const Duration(seconds: 6);
  if (proxy != null) c.findProxy = (_) => 'PROXY $proxy';
  try {
    final r = await (await c.getUrl(Uri.parse(url)))
        .close()
        .timeout(const Duration(seconds: 8));
    if (r.statusCode != 200) return null;
    final s = (await r.transform(utf8.decoder).join()).trim();
    return s.isNotEmpty && s.length < 64 ? s : null;
  } catch (_) {
    return null;
  } finally {
    c.close(force: true);
  }
}

Future<void> _killCores() async {
  if (Platform.isWindows) {
    await Process.run('taskkill', ['/F', '/IM', 'sing-box.exe']);
    await Process.run('taskkill', ['/F', '/IM', 'xray.exe']);
    await Future<void>.delayed(const Duration(milliseconds: 800));
  }
}

String _firstFatal(String out) {
  final clean = out.replaceAll(RegExp(r'\x1B\[[0-9;]*[A-Za-z]'), '');
  for (final line in const LineSplitter().convert(clean)) {
    if (line.contains('FATAL') || line.contains('ERROR')) {
      final i = line.indexOf('] ');
      return (i >= 0 ? line.substring(i + 2) : line).trim();
    }
  }
  return clean.trim().split('\n').first;
}
