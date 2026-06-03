// ignore_for_file: avoid_print
import 'package:vpn_app/core/diagnostics.dart';

/// Runs the built-in diagnostics against the real network (direct), to validate
/// the probe engine and show the actual RF blocking picture.
Future<void> main(List<String> args) async {
  final tunnel = args.contains('--tunnel');
  final results = await Diagnostics.run(
    throughTunnel: tunnel,
    onResult: (r) {
      final t = r.tunnelOk == null ? '' : ' tunnel=${r.tunnelOk! ? "OK" : "x"}';
      print('${r.blacklisted ? "B" : "W"} ${r.name.padRight(14)} '
          '${r.direct.name.padRight(12)} '
          'tcp=${r.tcpMs ?? "-"} tls=${r.tlsMs ?? "-"} '
          'dns_poison=${r.dnsPoisoned}$t');
    },
  );
  final bl = results.where((r) => r.blacklisted).toList();
  final blocked = bl.where((r) => r.direct != BlockVerdict.ok).length;
  final rescued = bl.where((r) => r.tunnelRescued).length;
  print('---');
  print('blacklist blocked direct: $blocked/${bl.length}');
  if (tunnel) print('blacklist rescued by tunnel: $rescued/${bl.length}');
}
