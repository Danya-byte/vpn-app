/// Builds the command-line + hostlist for the bundled zapret `winws.exe`
/// (WinDivert) DPI-desync sidecar — a SERVER-LESS bypass of SNI-based TLS-DPI
/// (the block class where the site IP is still reachable but the TLS handshake
/// is killed on the SNI: the diagnostic's "TLS DPI" verdict).
///
/// winws rewrites the outbound TLS ClientHello on the wire — it sends a FAKE
/// ClientHello (poisoning the DPI's SNI state) plus splits/reorders the REAL one
/// so the DPI can no longer see a full SNI in one segment, while the real server
/// still reassembles a valid handshake. It operates on ANY direct egress to
/// :80/:443 (the browser's own socket, or sing-box's direct outbound) — so it is
/// a pure additive layer, independent of the tunnel.
///
/// Pure / FFI-free so tools + tests import it. The actual desync is verified only
/// on RF hardware (needs the winws binary + WinDivert kernel driver + admin).
///
/// HONEST SCOPE: defeats TLS-DPI where the IP is still reachable. Does NOT defeat
/// IP-blocks (Telegram DC IPs, sanctioned-site drops) — winws can't route a
/// packet to an IP the network discards; those need a foreign exit. Simple TLS
/// fragmentation (the old sing-box `tls_fragment` path) was already removed
/// because ТСПУ reassembles it; the fake+disorder+TTL methods below are the
/// escalation that survives reassembly.
class DesyncConfig {
  /// Desync method presets (the `--dpi-desync*` action block applied per port).
  /// The exact best strategy is ISP/ТСПУ-specific (zapret ships `blockcheck` to
  /// discover it); these are sane, widely-working RF defaults.
  ///
  /// `fooling=md5sig` gives the FAKE packet a bad TCP-MD5 option so the real
  /// server silently drops it, but the DPI (which doesn't verify the option)
  /// still ingests it → its SNI tracking is poisoned by the decoy before the
  /// real, split ClientHello arrives. `autottl` auto-derives a TTL that reaches
  /// the DPI box but expires before the server, so the fake never reaches the
  /// origin. None of these need an external fake-payload file (winws has a
  /// built-in default ClientHello).
  static const strategies = <String, List<String>>{
    // DEFAULT - VERIFIED LIVE on a hard RF ISP (tool/winws-blockcheck.ps1): this
    // strategy turned YouTube + X + Discord + LinkedIn + Rutracker all from
    // TLS-kill to TLS-OK, server-less. fake decoy + MULTI-DISORDER (reorder the
    // real segments out of order at three SNI-targeted cut points: start, mid-SLD,
    // and just past the SNI extension) + `datanoack` fooling (the decoy carries
    // data with no ACK so the server ignores it but the DPI ingests it). datanoack
    // is the fooling this generation of ТСПУ doesn't classify; multidisorder is
    // what its reassembler can't put back together.
    //
    // The decoy is hardened with `fake-tls-mod=padencap,sni=gosuslugi.ru`: the FAKE
    // ClientHello carries a Russian-government SNI (which ТСПУ never blocks) and is
    // padded to the real record's length — so a STATEFUL / whitelist-leaning DPI
    // classifies the flow as benign (going to gosuslugi.ru) and is offset/sated
    // before the real split ClientHello lands. Same 5/5 live result as the bare
    // multidisorder, but survives a stateful classifier the bare form doesn't.
    'fake_split': [
      '--dpi-desync=fake,multidisorder',
      '--dpi-desync-split-pos=1,midsld,sniext+1',
      '--dpi-desync-fooling=datanoack',
      '--dpi-desync-fake-tls-mod=padencap,sni=gosuslugi.ru',
    ],
    // Alt - single disorder + datanoack (beat 4/5 in the same live test; lighter,
    // try if the default ever stutters on a path).
    'fake_disorder': [
      '--dpi-desync=fake,disorder2',
      '--dpi-desync-fooling=datanoack',
      '--dpi-desync-split-pos=1',
    ],
    // Gentle - plain split at the SNI, datanoack, no reorder (lowest collateral).
    'split': [
      '--dpi-desync=split2',
      '--dpi-desync-fooling=datanoack',
      '--dpi-desync-split-pos=sniext+1',
    ],
  };

  static const defaultStrategy = 'fake_split';

  static bool isValidStrategy(String s) => strategies.containsKey(s);

  /// Canonical RF TLS-DPI / throttle targets seeded into the hostlist. winws only
  /// touches connections whose SNI/Host matches an entry (suffix match — so
  /// `youtube.com` also covers `*.youtube.com`); everything else is untouched.
  /// IP-blocked entries (instagram/x) are harmless to list — winws tries, the
  /// handshake still can't reach a dropped IP, and the user falls back to a
  /// server for those. Unioned at runtime with [SingBoxConfig.desyncDomains] so
  /// a ТСПУ-fact feed push extends the list without a rebuild.
  // NOTE: the YouTube + Discord throttle clusters are intentionally NOT here —
  // they live in [SingBoxConfig.desyncDomains] (the feed-updatable throttle list),
  // which _spawnDesyncEngine unions with this. Listing them here too would be a
  // stale duplicate that drifts when the throttle list / feed changes.
  static const defaultHosts = <String>[
    // LinkedIn
    'linkedin.com', 'licdn.com',
    // Rutracker
    'rutracker.org', 'rutracker.net', 'rutrk.org',
    // Proton
    'proton.me', 'protonmail.com', 'protonvpn.com', 'protonmail.ch',
    // Meta (often IP-blocked too — listed for the SNI-only edge)
    'instagram.com', 'cdninstagram.com', 'facebook.com', 'fbcdn.net',
    // X / Twitter
    'x.com', 'twitter.com', 'twimg.com', 't.co',
    // misc commonly SNI-throttled in RF
    'soundcloud.com', 'sndcdn.com',
  ];

  /// Build the full winws argv for the given hostlist file + strategy.
  ///
  /// [hostlistPath] is written by the caller (one host per line via
  /// [hostlistContent]). [quicPayloadPath], when given, points at a REAL fake-QUIC
  /// Initial .bin (the zapret `quic_initial_*.bin` decoy) and enables a UDP/443
  /// (QUIC/HTTP-3) desync block — so a browser that opens HTTP/3 first to a
  /// throttled host (YouTube/Google) is desynced too, not left on a stalled QUIC
  /// path. WITHOUT the payload no UDP block is emitted (a payload-less `fake` would
  /// inject a garbage QUIC Initial and could BREAK HTTP/3 instead of helping).
  static List<String> winwsArgs({
    required String hostlistPath,
    String strategy = defaultStrategy,
    String? quicPayloadPath,
  }) {
    final method = strategies[strategy] ?? strategies[defaultStrategy]!;
    final args = <String>[
      // Global WinDivert capture window — ONLY these ports enter the engine, so
      // the kernel callout never touches the rest of the machine's traffic.
      '--wf-tcp=80,443',
      if (quicPayloadPath != null) '--wf-udp=443',
      // TCP/443 — the TLS ClientHello SNI surface (the main DPI target).
      '--filter-tcp=443',
      ...method,
      '--hostlist=$hostlistPath',
      '--new',
      // TCP/80 — the plaintext HTTP Host-header surface.
      '--filter-tcp=80',
      ...method,
      '--hostlist=$hostlistPath',
    ];
    if (quicPayloadPath != null) {
      args.addAll([
        '--new',
        // UDP/443 — QUIC/HTTP-3: inject a REAL fake QUIC Initial decoy (repeated)
        // to poison the DPI's QUIC SNI tracking; the real handshake still completes.
        '--filter-udp=443',
        '--dpi-desync=fake',
        '--dpi-desync-repeats=6',
        '--dpi-desync-fake-quic=$quicPayloadPath',
        '--hostlist=$hostlistPath',
      ]);
    }
    return args;
  }

  /// One validated host per line (lower-cased, de-duplicated, sorted). Invalid /
  /// non-hostname entries are dropped — a junk hostlist must never make winws
  /// desync arbitrary traffic.
  static String hostlistContent(Iterable<String> hosts) {
    final seen = <String>{};
    for (final h in hosts) {
      final c = cleanHost(h);
      if (c != null) seen.add(c);
    }
    final out = seen.toList()..sort();
    return out.isEmpty ? '\n' : '${out.join('\n')}\n';
  }

  // Hostname matcher for the BAKED desync hostlist (≤253 chars, LDH labels that
  // ALLOW consecutive hyphens so punycode `xn--` labels pass, real OR punycode
  // TLD). Deliberately its own matcher: route_rule._hostRe (routing + IP, user
  // input) and censorship_facts._isHostname (feed security-clamp) validate
  // DIFFERENT inputs with different strictness — sharing one regex would couple a
  // safety/security clamp to this list. Accepts IDN: `xn--p1ai` (.рф) etc.
  //
  // KNOWN, ACCEPTED looseness: it also accepts mid-label `--` on non-punycode
  // labels (`a--b.com`) and `_` in labels. Both are harmless here — winws does a
  // SUFFIX match against the live SNI, so a host that never appears as real SNI
  // simply never matches; it can't make winws desync arbitrary traffic. Bare IPs
  // / IPv6 literals are NOT hostnames and are intentionally rejected (the hostlist
  // is SNI/Host-name based, not address based).
  static final RegExp _hostRe = RegExp(
      r'^(?=.{1,253}$)([a-z0-9_]([a-z0-9_-]*[a-z0-9_])?\.)+([a-z]{2,63}|xn--[a-z0-9]{2,59})$');

  /// Normalise a raw entry to a bare hostname, or null if it isn't one. Strips a
  /// scheme, userinfo, path, port and a leading `*.` wildcard so a pasted URL
  /// still yields its host. Bare IPs / IPv6 literals return null by design.
  static String? cleanHost(String raw) {
    var s = raw.trim().toLowerCase();
    if (s.isEmpty) return null;
    s = s.replaceFirst(RegExp(r'^[a-z][a-z0-9+.-]*://'), ''); // scheme
    s = s.split('/').first.split('?').first.split('#').first; // path/query/frag
    if (s.contains('@')) s = s.split('@').last; // userinfo (user:pass@host)
    // Strip :port — but NOT inside an IPv6 literal `[..]` (which has many colons);
    // an IPv6 literal then fails _hostRe (no alpha TLD) and is dropped, as intended.
    if (!s.startsWith('[')) s = s.split(':').first;
    if (s.startsWith('*.')) s = s.substring(2); // wildcard
    if (s.endsWith('.')) s = s.substring(0, s.length - 1); // trailing dot
    if (!_hostRe.hasMatch(s)) return null;
    return s;
  }
}
