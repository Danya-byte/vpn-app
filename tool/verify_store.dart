import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:vpn_app/core/singbox_config.dart';

/// Connection doctor — one command, reproducible proof your setup works.
///
/// Takes your REAL stored profile, runs it through the EXACT runtime migration
/// the app uses, validates it with the bundled core (`sing-box check`), and —
/// with `--connect` — runs the core and proves real traffic flows through the
/// tunnel (exit IP via the local proxy differs from the direct IP). Prints a
/// plain PASS/FAIL so you can confirm the connection without trusting anyone.
///
///   dart run tool/verify_store.dart            # generate + validate
///   dart run tool/verify_store.dart --connect  # + run core + test live traffic
Future<void> main(List<String> args) async {
  final connect = args.contains('--connect');
  final cwd = Directory.current.path;
  final base = Platform.environment['LOCALAPPDATA']!;
  final store = File('$base\\vpn_app\\run\\profiles.json');
  if (!store.existsSync()) {
    stderr.writeln('профили не найдены: ${store.path}');
    exit(1);
  }
  final j = jsonDecode(store.readAsStringSync()) as Map<String, dynamic>;
  final nodes = (j['nodes'] as List).cast<Map<String, dynamic>>();
  final sel = j['selected']?.toString();
  final node =
      nodes.firstWhere((n) => n['tag'] == sel, orElse: () => nodes.first);
  if (node['config'] == null) {
    stderr.writeln('выбранный профиль — не полный конфиг (doctor проверяет '
        'конфиг-профили вроде «🌍 VPN»)');
    exit(1);
  }

  // Mimic the app exactly: bundled rule-sets so localization paths resolve, and
  // a Clash API secret so we validate the same secured control plane the app
  // ships (and can prove it actually rejects unauthenticated callers).
  SingBoxConfig.ruleSetDir = '$cwd\\core\\rule-sets';
  SingBoxConfig.clashSecret = 'doctor-secret-7f3a9c2e';
  final runtime = SingBoxConfig.fromConfig(
      (node['config'] as Map).cast<String, dynamic>());
  Directory('build').createSync(recursive: true);
  // build/ is gitignored — this holds your live credentials, never committed.
  final cfgPath = '$cwd\\build\\_runtime.json';
  File(cfgPath).writeAsStringSync(SingBoxConfig.encode(runtime));

  final outs = (runtime['outbounds'] as List).cast<Map>();
  stdout.writeln('профиль:        $sel');
  stdout.writeln('outbounds:      ${outs.length} '
      '(${outs.map((o) => o['type']).toSet().join(', ')})');
  stdout.writeln('dns.strategy:   ${(runtime['dns'] as Map?)?['strategy']}');
  stdout.writeln('конфиг:         build/_runtime.json');

  final sb = '$cwd\\core\\windows\\sing-box.exe';
  if (!File(sb).existsSync()) {
    stderr.writeln('sing-box.exe не найден: $sb (запусти tool/fetch-cores.ps1)');
    exit(1);
  }
  const env = {
    'ENABLE_DEPRECATED_LEGACY_DNS_SERVERS': 'true',
    'ENABLE_DEPRECATED_GEOSITE': 'true',
    'ENABLE_DEPRECATED_SPECIAL_OUTBOUNDS': 'true',
    'ENABLE_DEPRECATED_OUTBOUND_DNS_RULE_ITEMS': 'true',
    'ENABLE_DEPRECATED_DNS_RULE_ACTIONS': 'true',
    'ENABLE_DEPRECATED_MISSING_DOMAIN_RESOLVER': 'true',
  };

  // 1) Validate against the real core schema.
  final chk = await Process.run(sb, ['check', '-c', cfgPath], environment: env);
  final chkOk = chk.exitCode == 0;
  stdout.writeln('sing-box check: ${chkOk ? 'OK' : 'ОШИБКА'}');
  if (!chkOk) {
    stderr.writeln(_firstFatal('${chk.stderr}${chk.stdout}'));
    exit(2);
  }
  if (!connect) {
    stdout.writeln('\nКонфиг валиден. Тест живого трафика: '
        'dart run tool/verify_store.dart --connect');
    return;
  }

  // 2) Run the core and prove real traffic flows through the tunnel. This needs
  // the local port free, so stop any core the app is currently running.
  if (Platform.isWindows) {
    await Process.run('taskkill', ['/F', '/IM', 'sing-box.exe']);
    await Future<void>.delayed(const Duration(seconds: 1));
  }
  stdout.writeln('запускаю ядро…  (останавливаю VPN в приложении, если был включён)');
  final proc = await Process.start(sb, ['run', '-c', cfgPath],
      environment: env, workingDirectory: '$cwd\\build');
  try {
    final ip = await _exitIpThroughProxy();
    if (ip == null) {
      stdout.writeln('\nРЕЗУЛЬТАТ: туннель не отвечает — узлы недоступны из этой '
          'сети, либо сеть режет всё. Конфиг при этом валиден.');
      return;
    }
    final direct = await _directIp();
    stdout.writeln('прямой IP:      ${direct ?? '—'}');
    stdout.writeln('IP туннеля:     $ip');
    final tunneled = direct == null || ip != direct;

    // Control-plane security: the Clash API must ANSWER an authenticated caller
    // and REFUSE an anonymous one (else any local app / web page could read your
    // connections and switch your exit node).
    final authed = await _clashStatus(SingBoxConfig.clashSecret);
    final anon = await _clashStatus(null);
    final guarded = authed == 200 && anon == 401;
    stdout.writeln('Clash API:      ${guarded ? 'защищён секретом (anon → 401, '
        'auth → 200)' : 'auth=$authed anon=$anon'}');

    stdout.writeln('\nРЕЗУЛЬТАТ: ${tunneled ? 'ТРАФИК ИДЁТ ЧЕРЕЗ ТУННЕЛЬ — соединение работает' : 'туннель отвечает, но IP = прямому (проверь маршрутизацию)'}');
  } finally {
    proc.kill();
    await proc.exitCode
        .timeout(const Duration(seconds: 5), onTimeout: () => -1);
  }
}

Future<String?> _exitIpThroughProxy() async {
  // Poll up to ~22s while the proxy comes up and urltest picks a live node.
  for (var i = 0; i < 22; i++) {
    final ip = await _fetch('http://api.ipify.org',
        proxy: '${SingBoxConfig.mixedListen}:${SingBoxConfig.mixedPort}');
    if (ip != null) return ip;
    await Future<void>.delayed(const Duration(seconds: 1));
  }
  return null;
}

Future<String?> _directIp() => _fetch('http://api.ipify.org');

/// HTTP status from the Clash API /version, optionally with a Bearer [secret].
/// 200 = served, 401 = rejected (unauthenticated). null = unreachable.
Future<int?> _clashStatus(String? secret) async {
  final c = HttpClient()..connectionTimeout = const Duration(seconds: 3);
  try {
    final req = await c.getUrl(Uri.parse('http://127.0.0.1:9090/version'));
    if (secret != null && secret.isNotEmpty) {
      req.headers.set(HttpHeaders.authorizationHeader, 'Bearer $secret');
    }
    final resp = await req.close().timeout(const Duration(seconds: 4));
    return resp.statusCode;
  } catch (_) {
    return null;
  } finally {
    c.close(force: true);
  }
}

Future<String?> _fetch(String url, {String? proxy}) async {
  final c = HttpClient()..connectionTimeout = const Duration(seconds: 6);
  if (proxy != null) c.findProxy = (_) => 'PROXY $proxy';
  try {
    final req = await c.getUrl(Uri.parse(url));
    final resp = await req.close().timeout(const Duration(seconds: 8));
    if (resp.statusCode != 200) return null;
    final s = (await resp.transform(utf8.decoder).join()).trim();
    return s.isNotEmpty && s.length < 64 ? s : null;
  } catch (_) {
    return null;
  } finally {
    c.close(force: true);
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
  return clean.trim();
}
