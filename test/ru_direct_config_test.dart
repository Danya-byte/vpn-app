import 'package:flutter_test/flutter_test.dart';
import 'package:vpn_app/core/singbox_config.dart';

/// Locks in RU-direct injection for imported full-configs (closes the confirmed
/// vtb/gov reverse-geo-block: a proxy-everything config sends RU-domestic sites
/// through the foreign exit, which sanctioned RU sites refuse). Must be safe:
/// only in Smart mode, only with bundled .srs, idempotent, no duplicate rule-set
/// tags (a dup FATALs the core).
void main() {
  setUp(() {
    SingBoxConfig.ruleSetDir = r'core\rule-sets'; // non-empty → injection armed
    SingBoxConfig.ruleSetsReady = true;
  });
  tearDown(() {
    SingBoxConfig.ruleSetDir = '';
  });

  Map<String, dynamic> proxyEverything() => {
        'outbounds': [
          {
            'type': 'vless',
            'tag': 'proxy',
            'server': 'a.example',
            'server_port': 443,
            'uuid': 'u',
          },
        ],
        'route': {'rules': <dynamic>[], 'final': 'proxy'},
      };

  bool hasRuDirect(Map<String, dynamic> cfg) {
    final rules = (cfg['route'] as Map)['rules'] as List;
    return rules.any((r) {
      if (r is! Map || r['outbound'] != 'direct') return false;
      final rs = r['rule_set'];
      final tags = rs is List ? rs.map((e) => '$e').toList() : const [];
      return tags.contains('geoip-ru') && tags.contains('geosite-ru');
    });
  }

  test('Smart mode injects RU-geo + private-IP -> direct into an imported config',
      () {
    final cfg = SingBoxConfig.fromConfig(proxyEverything(), ruDirect: true);
    expect(hasRuDirect(cfg), isTrue, reason: 'RU-geo -> direct rule missing');

    final rules = (cfg['route'] as Map)['rules'] as List;
    expect(rules.any((r) => r is Map && r['ip_is_private'] == true), isTrue,
        reason: 'private-IP -> direct missing');

    // A direct outbound must exist to route RU traffic to.
    final outs = cfg['outbounds'] as List;
    expect(outs.any((o) => o is Map && o['type'] == 'direct'), isTrue);

    // The rule-set definitions must be present exactly once (dup tag = FATAL).
    final defs = (cfg['route'] as Map)['rule_set'] as List? ?? const [];
    final tags = defs.whereType<Map>().map((e) => e['tag']).toList();
    expect(tags.where((t) => t == 'geoip-ru').length, 1);
    expect(tags.where((t) => t == 'geosite-ru').length, 1);
  });

  test('Global mode (ruDirect:false) leaves the imported routing untouched', () {
    final cfg = SingBoxConfig.fromConfig(proxyEverything(), ruDirect: false);
    expect(hasRuDirect(cfg), isFalse);
  });

  test('idempotent: a config that already routes RU direct is not doubled', () {
    final pre = proxyEverything();
    (pre['route'] as Map)['rules'] = [
      {
        'rule_set': ['geoip-ru', 'geosite-ru'],
        'outbound': 'direct',
      },
    ];
    (pre['outbounds'] as List).add({'type': 'direct', 'tag': 'direct'});
    final cfg = SingBoxConfig.fromConfig(pre, ruDirect: true);
    final rules = (cfg['route'] as Map)['rules'] as List;
    final ruRules = rules.where((r) {
      if (r is! Map) return false;
      final rs = r['rule_set'];
      return rs is List && rs.contains('geoip-ru');
    });
    expect(ruRules.length, 1, reason: 'RU-direct rule was duplicated');
  });

  test('no bundled rule-sets → no injection (never reference a missing .srs)',
      () {
    SingBoxConfig.ruleSetDir = '';
    final cfg = SingBoxConfig.fromConfig(proxyEverything(), ruDirect: true);
    expect(hasRuDirect(cfg), isFalse);
  });
}
