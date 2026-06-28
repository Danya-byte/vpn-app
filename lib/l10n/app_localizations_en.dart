// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for English (`en`).
class AppLocalizationsEn extends AppLocalizations {
  AppLocalizationsEn([String locale = 'en']) : super(locale);

  @override
  String get appTitle => 'VPN App';

  @override
  String get navHome => 'Home';

  @override
  String get navActivity => 'Activity';

  @override
  String get navSettings => 'Settings';

  @override
  String get trayConnect => 'Connect';

  @override
  String get trayInsecureHint =>
      'This server skips certificate checks — confirm it once in the app first.';

  @override
  String get trayDisconnect => 'Disconnect';

  @override
  String get trayShow => 'Show';

  @override
  String get trayQuit => 'Quit';

  @override
  String get tabConnections => 'Connections';

  @override
  String get tabLogs => 'Logs';

  @override
  String get coreSubtitle => 'sing-box • Windows';

  @override
  String get statusConnected => 'Connected';

  @override
  String get statusChecking => 'Checking connection…';

  @override
  String get statusConnecting => 'Connecting…';

  @override
  String get statusDisconnecting => 'Disconnecting…';

  @override
  String get statusDisconnected => 'Disconnected';

  @override
  String get statusError => 'Error';

  @override
  String get profiles => 'Profiles';

  @override
  String get profilesEmpty =>
      'No servers yet. Paste a link, scan a QR, or open a file.';

  @override
  String get adminDropHint =>
      'Admin mode: drag a config / link onto the window — no hover highlight, but the import works.';

  @override
  String get clipboardOfferText => 'A server link is on your clipboard';

  @override
  String fastestServer(String tag) {
    return 'Fastest: $tag';
  }

  @override
  String get noReachableServer => 'No server is reachable from here';

  @override
  String get diagDesyncOfferText =>
      'These sites are throttled by TLS-DPI — the server-less bypass can open them with no server.';

  @override
  String get diagDesyncOfferAction => 'Enable server-less bypass';

  @override
  String get diagDesyncOfferDone => 'Server-less DPI bypass enabled';

  @override
  String get renameAction => 'Rename';

  @override
  String get deleteAction => 'Delete';

  @override
  String get moreActions => 'More';

  @override
  String get renameInvalid => 'Name is empty or already taken';

  @override
  String get hardNetworkCtaText =>
      'Not connecting? Mobile operators block harder than Wi-Fi.';

  @override
  String get hardNetworkCtaAction => 'Make it work';

  @override
  String get hardNetworkCtaDone => 'Hard-network mode on — reconnecting';

  @override
  String get hardNetworkCtaAlready => 'Hard-network mode is already on';

  @override
  String get hardNetworkCtaFailed =>
      'Could not reconnect — try toggling off and on';

  @override
  String get updateOpenFailed => 'Could not open the download page';

  @override
  String get noProfile => 'No profile';

  @override
  String get tapToAdd => 'tap to add';

  @override
  String get core => 'Core';

  @override
  String get coreNotRunning => 'sing-box (not running)';

  @override
  String get localProxy => 'Local proxy';

  @override
  String get upload => 'Upload';

  @override
  String get download => 'Download';

  @override
  String coreLogsTitle(int count) {
    return 'Core logs ($count)';
  }

  @override
  String get copy => 'Copy';

  @override
  String get copied => 'Logs copied';

  @override
  String get empty => 'Empty';

  @override
  String get btnLinkList => 'Link / list';

  @override
  String get btnSubscriptionUrl => 'Subscription URL';

  @override
  String get btnFromClipboard => 'From clipboard';

  @override
  String get btnFromFile => 'From file';

  @override
  String get btnScanScreenQr => 'Scan QR on screen';

  @override
  String get btnExport => 'Export profiles…';

  @override
  String get exportDone => 'Profiles exported';

  @override
  String get addProfile => 'Add profile';

  @override
  String get dlgImportTitle => 'Link or subscription';

  @override
  String get dlgImportHint => 'vless://…  (multiple lines or base64 too)';

  @override
  String get cancel => 'Cancel';

  @override
  String get importAction => 'Import';

  @override
  String get dlgUrlTitle => 'Subscription by URL';

  @override
  String get dlgUrlHint => 'https://…';

  @override
  String get loadAction => 'Load';

  @override
  String msgAddedNodes(int count) {
    return 'Added $count nodes';
  }

  @override
  String switchedTo(String member) {
    return 'Switched to $member';
  }

  @override
  String get msgNotRecognized => 'No nodes recognized';

  @override
  String get msgQrNotFound => 'No QR code found in the image';

  @override
  String get msgSubscriptionEmpty => 'Subscription is empty';

  @override
  String get msgClipboardEmpty => 'No nodes in clipboard';

  @override
  String get msgAlreadyImported => 'Already imported — reconnecting';

  @override
  String msgLoadError(String error) {
    return 'Load error: $error';
  }

  @override
  String get modeGlobal => 'Global';

  @override
  String get modeSmart => 'Smart';

  @override
  String get modeGlobalDesc => 'All traffic through proxy';

  @override
  String get modeSmartDesc => 'RU & local direct, rest through proxy';

  @override
  String get language => 'Language';

  @override
  String get languageSystem => 'System';

  @override
  String get about => 'About';

  @override
  String get version => 'Version';

  @override
  String get developer => 'Developer';

  @override
  String get sourceCode => 'Source code (GitHub)';

  @override
  String get factsFeed => 'Censorship facts';

  @override
  String get factsFeedBuiltIn => 'Built-in (updates on connect)';

  @override
  String get vpnModeTitle => 'VPN mode';

  @override
  String get antiDpiTitle => 'Anti-DPI (TLS fragment)';

  @override
  String get antiDpiDesc =>
      'Fragments the TLS handshake to beat SNI-based DPI. Slightly slower.';

  @override
  String get antiDpiForcedHint => 'Forced on by Hard-network mode';

  @override
  String get maxResistTitle => 'Hard-network mode (mobile operator)';

  @override
  String get maxResistDesc =>
      'Mobile networks block far harder than Wi-Fi. Forces TLS fragmentation ON and keeps the survivor-preferring cascade active, regardless of the other switches. Turn on when it works on Wi-Fi but not on mobile.';

  @override
  String get desyncTitle => 'Unblock without a server';

  @override
  String get desyncDesc =>
      'A packet-level engine that desyncs the outgoing TLS handshake so the censor can\'t read the site name (SNI) — unblocks throttled / SNI-DPI sites (YouTube, Discord, Rutracker…) right on your device, with NO server. Needs administrator (loads a network driver). Doesn\'t beat a full IP block — that still needs a server.';

  @override
  String get tgUnblockTitle => 'Telegram without a server';

  @override
  String get tgUnblockDesc =>
      'Restores Telegram CALLS (blocked Aug 2025 by a packet signature) and steadies messaging, on-device — no server. Targets Telegram\'s own servers by address and fools the signature filter. Needs administrator. Media stays slow and the southern regions / full shutdowns still need a server — that\'s an IP block, not a signature.';

  @override
  String get tgWsTitle => 'Telegram without a server (experimental)';

  @override
  String get tgWsDesc =>
      'Experimental, no server / no admin: re-wraps Telegram\'s traffic as an HTTPS connection to web.telegram.org to dodge the signature throttle. It may not carry a working session yet — test it before relying on it, and it can\'t beat a hard IP-block. Calls aren\'t covered here (use the toggle above).';

  @override
  String get tgWsHowto =>
      'In Telegram → Settings → Advanced → Connection → SOCKS5, point it here, then turn your VPN off.';

  @override
  String get tgWsPathOk => 'web.telegram.org reachable (try sending a message)';

  @override
  String get tgWsPathFail =>
      'web.telegram.org unreachable — your operator blocks it too (needs a server)';

  @override
  String get tgWsBlockedHint =>
      'Your operator IP-blocks web.telegram.org — no serverless fix exists for media here. Your own clean exit IP routes Telegram (media too) around the block.';

  @override
  String get tgWsMakeServer => 'Create your own server for Telegram';

  @override
  String get tgNativeTitle => 'Telegram without a server (native)';

  @override
  String get tgNativeDesc =>
      'A local engine (tgcore) that wraps Telegram in a WebSocket to its un-throttled web gateway, disguised as your real browser. No server. The bridge needs no administrator; calls do.';

  @override
  String get tgNativeOpenInTg => 'Open in Telegram';

  @override
  String get tgNativeRunning => 'Running — open the link in Telegram';

  @override
  String get tgNativeCapturing => 'Capturing your browser fingerprint…';

  @override
  String get tgNativeUnavailable =>
      'Engine unavailable — binary missing or it stopped.';

  @override
  String get tgNativeCalls => 'Calls (desync, needs administrator)';

  @override
  String get tgNativeSetupFp => 'Match my browser';

  @override
  String get tgWsChecking => 'Checking the path…';

  @override
  String get tgWsRecheck => 'Re-check the path';

  @override
  String get tgWsConns => 'live';

  @override
  String get desyncActive => 'DPI bypass active';

  @override
  String get desyncNeedsAdmin =>
      'Needs administrator — restart elevated to load the bypass driver.';

  @override
  String get desyncMissing =>
      'Engine not installed — put winws.exe + WinDivert in core\\windows.';

  @override
  String get desyncIdle => 'Engaging — no connection needed.';

  @override
  String get desyncTryNext => 'Try next method';

  @override
  String get desyncTryingNext =>
      'Trying the next bypass method — check if the site opens now';

  @override
  String get desyncNoMore =>
      'Tried every method — this site is likely IP-blocked (needs a server, not just desync)';

  @override
  String get desyncStrategyLabel => 'Method';

  @override
  String get desyncStratFakeSplit => 'Split+fake';

  @override
  String get desyncStratFakeDisorder => 'Disorder';

  @override
  String get desyncStratSplit => 'Split';

  @override
  String get autoFailoverTitle => 'Auto-failover';

  @override
  String get autoFailoverDesc =>
      'urltest over all nodes: fastest working one, auto-switch when blocked.';

  @override
  String get restartAsAdmin => 'Restart as administrator';

  @override
  String get refreshSubs => 'Refresh subscriptions';

  @override
  String get pingAll => 'Measure latency (no connection)';

  @override
  String get pingAllWhileOn =>
      'Measure before connecting — live latency is in Activity → Policies';

  @override
  String get pinCertAction => 'Pin certificate';

  @override
  String get pinCertTitle => 'Pin server certificate';

  @override
  String get pinCertHint =>
      'Paste the server\'s certificate (PEM, -----BEGIN CERTIFICATE-----…)';

  @override
  String get pinCertDone =>
      'Certificate pinned — verification is on, no longer insecure';

  @override
  String get pinCertInvalid => 'That isn\'t a valid PEM certificate';

  @override
  String get pinCertMulti =>
      'This config has several insecure servers — per-server pinning isn\'t supported yet';

  @override
  String get unpinCertAction => 'Remove pinned certificate';

  @override
  String get unpinCertConfirm =>
      'Remove the pinned certificate? The server goes back to no-verification (insecure) until you pin the correct one.';

  @override
  String get unpinCertDone => 'Pinned certificate removed';

  @override
  String get pinnedBadge => 'verified';

  @override
  String get subsUpToDate => 'Subscriptions up to date';

  @override
  String get createOwnNode => 'Create your own node';

  @override
  String get routingMode => 'Routing mode';

  @override
  String get vpnModeProxy => 'Proxy';

  @override
  String get vpnModeTun => 'TUN';

  @override
  String get vpnModeProxyDesc =>
      'Only browsers and proxy-aware apps go through the tunnel — no admin needed. Other apps and their DNS go DIRECT (real IP exposed). For full protection use TUN mode.';

  @override
  String get proxyAppsHint =>
      'Apps that ignore the system proxy — Telegram desktop & its calls, CLI tools — only ride the tunnel in TUN mode, OR point their own SOCKS5 proxy at the address below (Telegram: Settings → Advanced → Connection type → SOCKS5 — this carries calls too).';

  @override
  String get proxyAddrCopied => 'Local proxy address copied';

  @override
  String get vpnModeTunDesc =>
      'All system traffic via a VPN adapter (every app, UDP). Needs administrator.';

  @override
  String get serverGenDesc =>
      'Your own VPS → a clean IP that isn\'t on RKN lists + Reality masquerade as a real site = operator-proof.';

  @override
  String get serverGenIp => 'Your VPS IP';

  @override
  String serverGenMasquerade(String sni) {
    return 'Masquerade as $sni';
  }

  @override
  String get generating => 'Generating…';

  @override
  String get generate => 'Generate';

  @override
  String get serverGenStep1 =>
      '1. Setup script (paste on the VPS over SSH as root)';

  @override
  String get serverGenStep2 => '2. Add the client profile';

  @override
  String get serverGenAdded =>
      'Profiles added (Reality + Hysteria2). Deploy the server with the script and connect.';

  @override
  String get noConnections => 'No active connections';

  @override
  String get connectionsConnect => 'Connect the VPN to see active connections.';

  @override
  String connectionsActive(int count) {
    return '$count active';
  }

  @override
  String get viewConfig => 'sing-box config';

  @override
  String get dropToImport => 'Drop a config, link, or QR to import';

  @override
  String get onboardTitle => 'Add your first server';

  @override
  String get onboardBody =>
      'Drop a QR or config file, paste a share link, or open a file — then tap connect.';

  @override
  String get setupTitle => 'Choose your protection';

  @override
  String get setupBody =>
      'How should the VPN protect this PC? You can change this anytime in Settings.';

  @override
  String get setupTunTitle => 'Full-device protection';

  @override
  String get setupTunBody =>
      'Routes every app through the tunnel — no DNS or IPv6 leaks. Asks for admin rights when connecting.';

  @override
  String get setupTunBadge => 'Most secure';

  @override
  String get setupProxyTitle => 'App proxy';

  @override
  String get setupProxyBody =>
      'Simpler and needs no admin, but only proxy-aware apps are covered — other traffic can go direct.';

  @override
  String get setupProxyBadge => 'Simple';

  @override
  String get delete => 'Delete';

  @override
  String deleteProfileConfirm(String name) {
    return 'Delete \"$name\"?';
  }

  @override
  String get measuring => 'measuring…';

  @override
  String get serverGenInvalidIp => 'Enter a valid IP address';

  @override
  String get serverGenFailed =>
      'Generation failed — check the core and try again';

  @override
  String get importFailed =>
      'Imported, but the tunnel did not come up with this profile';

  @override
  String get importNoTraffic =>
      'Connected, but no traffic — this server may be unreachable';

  @override
  String get importNotConnected =>
      'Imported — not connected. Review it in the list.';

  @override
  String get importDiscarded => 'Discarded';

  @override
  String get importReviewTitle => 'Imported server';

  @override
  String get importProtocol => 'Protocol';

  @override
  String get importServer => 'Server';

  @override
  String get importConfigProfile => 'sing-box config';

  @override
  String get importExit => 'Route';

  @override
  String get importRoutesDirect =>
      'This config sends all traffic DIRECT — no VPN protection';

  @override
  String get importConnectAction => 'Connect';

  @override
  String get importExternalWarning =>
      'This server came from an external link or QR code. A hostile server can see and tamper with all your traffic — connect only if you trust the source.';

  @override
  String get importFetchTitle => 'Download server list?';

  @override
  String importFetchBody(String host) {
    return '$host will receive your IP address and the app will load a server list it provides. Continue only if you trust this link.';
  }

  @override
  String get importFetchInsecure =>
      'This is an http:// (cleartext) link — the server list can be tampered with on the way. Prefer an https:// link.';

  @override
  String get importContinue => 'Continue';

  @override
  String get errCoreMissing => 'Core binary not found. Reinstall the app.';

  @override
  String get errTunNeedsAdmin =>
      'TUN mode needs administrator.\nSettings → VPN mode → Restart as administrator.';

  @override
  String errConfigRejected(String detail) {
    return 'The core rejected the config:\n$detail';
  }

  @override
  String errWriteFailed(String detail) {
    return 'Could not write the config: $detail';
  }

  @override
  String errLaunchFailed(String detail) {
    return 'Could not start the core: $detail';
  }

  @override
  String get errNoApi => 'The core started but did not answer the Clash API.';

  @override
  String get errReconnecting =>
      'Connection lost — reconnecting (traffic blocked, no leak)…';

  @override
  String get errGaveUp =>
      'Could not connect after several tries — check the profile or network.';

  @override
  String get errKillSwitchFailed =>
      'Kill-switch is ON but the firewall fence could not be installed — not connecting unprotected. Run the app as administrator, or turn the kill-switch off in Settings.';

  @override
  String get errProxyFailed =>
      'Could not set the system proxy — not connecting (apps would go direct, unprotected). Check Windows proxy/registry permissions.';

  @override
  String get errXrayMissing =>
      'This profile needs the xray bridge (xray.exe), which is missing from the install. Reinstall the app or restore xray.exe.';

  @override
  String updateAvailable(String version) {
    return 'Update available: $version';
  }

  @override
  String get updateNow => 'Update';

  @override
  String get updateBannerHint =>
      'Open the release page to download the new version.';

  @override
  String get serverGenChainToggle => 'Domestic-relay chain (2 VPS)';

  @override
  String get serverGenChainDesc =>
      'A Russian-cloud relay (fronts a real RU site) forwards to a foreign exit. ТСПУ sees only domestic RU-IP ↔ RU-SNI traffic — operator-proof.';

  @override
  String get serverGenRelayIp => 'RU relay VPS IP';

  @override
  String get serverGenExitIp => 'Foreign exit VPS IP';

  @override
  String get serverGenRelayScript => '1a. Relay setup (run on the RU VPS)';

  @override
  String get serverGenExitScript => '1b. Exit setup (run on the foreign VPS)';

  @override
  String get serverGenChainAdded =>
      'Chain profile added — connect; ТСПУ sees only domestic traffic.';

  @override
  String get diagnostics => 'Diagnostics';

  @override
  String get diagRun => 'Check my network';

  @override
  String get diagChecking => 'Checking…';

  @override
  String get diagControls => 'Controls (should load in RF)';

  @override
  String get diagBlocked => 'RKN-blocked (VPN should fix)';

  @override
  String get diagDirect => 'Direct';

  @override
  String get diagViaVpn => 'Via VPN';

  @override
  String diagRescued(int count, int total) {
    return 'VPN unblocks $count of $total blocked sites';
  }

  @override
  String get diagConnectHint =>
      'Connect the VPN to compare the “Via VPN” column.';

  @override
  String get vOk => 'OK';

  @override
  String get vDnsPoisoned => 'DNS poisoned';

  @override
  String get vTlsDpi => 'TLS DPI';

  @override
  String get vTcpReset => 'TCP reset';

  @override
  String get vTimeout => 'Timeout';

  @override
  String get vDown => 'Down';

  @override
  String get serverDiagRun => 'Diagnose my server';

  @override
  String get serverDiagTunHint =>
      'Disconnect (or use proxy mode) to test — TUN captures the probe';

  @override
  String get serverDiagHint =>
      'Probes your selected server raw (bypassing the tunnel) to show where the connection breaks here — for when it works on Wi-Fi but not on mobile.';

  @override
  String get serverDiagHeader => 'My server(s)';

  @override
  String get serverDiagNone => 'Select a server first.';

  @override
  String get serverDiagCopy => 'Copy report';

  @override
  String get serverDiagCopied => 'Diagnostic report copied';

  @override
  String get svReachableL4 => 'reaches (L4 OK)';

  @override
  String get svServerBlocked => 'IP/port blocked';

  @override
  String get svWhitelist => 'whitelist — foreign dark';

  @override
  String get svUdpInconclusive => 'UDP — can\'t probe';

  @override
  String get svDnsInconclusive => 'DNS unclear — can\'t verify';

  @override
  String get svOffline => 'Offline';

  @override
  String get tlsFpTitle => 'Browser fingerprint';

  @override
  String get tlsFpDesc =>
      'Mimic this browser\'s TLS handshake. “random” rotates among real browsers each connection.';

  @override
  String get muxTitle => 'Multiplex (mux)';

  @override
  String get muxDesc =>
      'Carry many streams over one TLS connection — fewer connections for DPI to fingerprint. Skipped on Vision/QUIC.';

  @override
  String subDaysLeft(int days) {
    return '$days d left';
  }

  @override
  String get subExpired => 'expired';

  @override
  String get autoAdaptTitle => 'Auto-adapt to blocking';

  @override
  String get autoAdaptDesc =>
      'If ТСПУ starts choking the live tunnel, automatically cycle the TLS fingerprint / fragmentation / mux until traffic flows again — no manual fiddling.';

  @override
  String get errPortInUse =>
      'Local port is busy — another copy of the app is running (maybe as administrator). Close it, then reconnect.';

  @override
  String get connectOnLaunchTitle => 'Connect on launch';

  @override
  String get connectOnLaunchDesc =>
      'If the VPN was on when you closed the app, reconnect automatically the next time it opens.';

  @override
  String get registerLinksTitle => 'Open vpn:// links & configs with this app';

  @override
  String get registerLinksDesc =>
      'Register vpn:// / sing-box:// links and add this app to the .json \"Open with\" list, so a clicked link or config imports here. No admin needed.';

  @override
  String get autostartTitle => 'Launch at startup';

  @override
  String get autostartDesc =>
      'Start the app when you sign in to Windows. No admin. In TUN mode the tunnel still needs admin, so pair this with proxy mode for a UAC-free start.';

  @override
  String get closeToTrayTitle => 'Keep running in the tray on close';

  @override
  String get closeToTrayDesc =>
      'Closing the window hides it to the tray and keeps the tunnel running. Open it again from the tray icon, or right-click the icon → Quit to exit.';

  @override
  String get errWireguardHandshake =>
      'WireGuard handshake never completed — the tunnel connects but carries no traffic. The server may be down, or this is an AmneziaWG config: its obfuscation isn\'t supported by the core (which speaks plain WireGuard), and plain WireGuard is throttled in Russia. Use a VLESS+Reality or Hysteria2 node instead.';

  @override
  String get insecureBadge => 'no cert check';

  @override
  String get policies => 'Policies';

  @override
  String get policiesEmpty =>
      'This profile has no switchable groups.\nOnly multi-node configs (Selector / URLTest) have policies.';

  @override
  String get policyAuto => 'auto';

  @override
  String get policyTestAll => 'Test all';

  @override
  String get policyAlive => 'Live nodes (answered the through-tunnel probe)';

  @override
  String get policyTimeout => 'timeout';

  @override
  String get policiesPreview =>
      'Preview — connect to switch servers and measure ping.';

  @override
  String get speedTestRun => 'Test';

  @override
  String get speedTestRetry => 'Again';

  @override
  String get speedTestHint => 'Real throughput through the tunnel';

  @override
  String get speedTestConnect => 'Connect to run a speed test';

  @override
  String get speedTestDownloading => 'Download…';

  @override
  String get speedTestUploading => 'Upload…';

  @override
  String get killSwitchActive => 'Kill-switch on';

  @override
  String get killSwitchUnprotected => 'Kill-switch ON but NOT protected';

  @override
  String get proxyModeLeakHint =>
      'Proxy mode — apps that ignore the system proxy go direct';

  @override
  String get whitelistModeTitle => 'Whitelist mode';

  @override
  String get whitelistModeBody =>
      'Your mobile network has been cut back to a state-approved allowlist — only Russian sites are reachable, no foreign exit works. This isn\'t a blocked node; use Wi-Fi or a domestic relay.';

  @override
  String get unblockHint =>
      'The kill-switch blocked all traffic after the tunnel gave up.';

  @override
  String get unblockAction => 'Disconnect & unblock';

  @override
  String get insecureConnectTitle => 'Connect without certificate checks?';

  @override
  String get insecureConnectBody =>
      'This server turns off TLS certificate validation, so a network attacker could read or alter your traffic. Connect anyway?';

  @override
  String get insecureConnectAction => 'Connect anyway';

  @override
  String get splitTunnelTitle => 'Per-app routing (TUN)';

  @override
  String get splitTunnelDesc =>
      'Route specific processes per-app. DIRECT bypasses the VPN — only for apps that work WITHOUT one and want low ping (e.g. a game on RU servers). THROUGH VPN pins a blocked app (Discord, blocked games) to the tunnel so it always works. Add the exact .exe name.';

  @override
  String get splitDirectLabel => 'Direct (bypass VPN)';

  @override
  String get splitVpnLabel => 'Force through VPN';

  @override
  String get splitTunnelHint => 'process.exe';

  @override
  String get splitCommonApps => 'Common apps:';

  @override
  String get splitTunnelEmpty => 'None';

  @override
  String get tunOnlyHint => 'Works only in TUN mode.';

  @override
  String get customRulesTitle => 'Custom routing rules';

  @override
  String get customRulesDesc =>
      'Force specific destinations through the tunnel, keep them direct, or block them. These win over Smart routing. Match a domain (and its sub-domains), an exact host, or an IP/CIDR.';

  @override
  String get customRulesEmpty => 'No rules — Smart routing decides everything';

  @override
  String get customRulesValueHint => 'openai.com  or  1.2.3.4/24';

  @override
  String get transportBlockedWarn =>
      'This transport (e.g. plain WireGuard / Shadowsocks) is widely blocked in Russia — prefer Reality, Hysteria2 or XHTTP.';

  @override
  String get amneziaNoBridge =>
      'AmneziaWG config — but the AmneziaWG bridge (awg.exe) isn\'t installed, so this falls back to plain WireGuard, which an Amnezia server rejects (it won\'t connect). A normal WireGuard .conf works as-is.';

  @override
  String get fakeIpTitle => 'Faster DNS (TUN)';

  @override
  String get fakeIpDesc =>
      'Answer apps instantly with a placeholder address and resolve the real one at the exit — cuts first-load lag in TUN mode and avoids DNS leaks. Experimental; turn off if a site won\'t open.';

  @override
  String get advancedTitle => 'Expert transport';

  @override
  String get advancedDesc =>
      'Expert transport knobs. Leave default unless you know you need them.';

  @override
  String get tunStackTitle => 'TUN network stack';

  @override
  String get tunStackDesc =>
      'gVisor is the safe default; system/mixed lower overhead but lean on the OS stack.';

  @override
  String get muxProtoTitle => 'Multiplex protocol (needs multiplex on)';

  @override
  String get muxPaddingTitle => 'Multiplex padding';

  @override
  String get muxPaddingDesc => 'Pad multiplexed streams to hide their sizes.';

  @override
  String get echTitle => 'Encrypted ClientHello (ECH)';

  @override
  String get echDesc =>
      'Auto-discovers each node\'s published ECH config over DNS and hides the real TLS server name behind a cover name — like Chrome. Best for Cloudflare-fronted nodes; harmless when a node has none.';

  @override
  String get ecsTitle => 'DNS Client Subnet (ECS)';

  @override
  String get ecsDesc =>
      'Send resolvers a subnet for better CDN locality. Empty = off.';

  @override
  String get ecsHint => 'e.g. 1.2.3.0/24';

  @override
  String get ecsInvalid => 'Invalid subnet — use a form like 1.2.3.0/24';

  @override
  String get tfoTitle => 'TCP Fast Open';

  @override
  String get tfoDesc =>
      'Saves ~1 RTT on connect. Off by default — can break some servers and mobile-operator paths in Russia.';

  @override
  String get mptcpTitle => 'Multipath TCP';

  @override
  String get mptcpDesc =>
      'Use multiple network paths when the server supports it. Advanced.';

  @override
  String get shareImportTitle => 'Imported shared setup';

  @override
  String get shareApplySettings => 'Apply the sender\'s protection settings';

  @override
  String get shareApplySettingsDesc =>
      'DPI bypass, per-app routing and rules from the share — only if you trust the sender.';

  @override
  String get shareAutoUpdateNote =>
      'This profile auto-updates from the sender\'s link.';

  @override
  String get shareTitle => 'Share';

  @override
  String get shareForAnyClient => 'For any app';

  @override
  String get shareForAnyClientDesc =>
      'Standard links any VPN client can import — servers only, no settings.';

  @override
  String get shareWithSettings => 'With my settings';

  @override
  String get shareWithSettingsDesc =>
      'Our app only — also shares your DPI bypass + routing setup.';

  @override
  String get shareCopied => 'Link copied to clipboard';

  @override
  String get shareCopyLink => 'Copy link';

  @override
  String get shareNothing => 'Nothing to share yet — add a server first.';

  @override
  String get shareNoUniversal =>
      'These profiles are whole configs — standard links can\'t carry them. Use \"With my settings\" instead.';

  @override
  String get customRulesInvalid => 'Invalid domain or IP — not added';

  @override
  String get customRulesLiveNote =>
      'Changes apply immediately and briefly reconnect an active tunnel.';

  @override
  String get ruleFieldDomainSuffix => 'Domain';

  @override
  String get ruleFieldDomain => 'Exact host';

  @override
  String get ruleFieldIpCidr => 'IP / CIDR';

  @override
  String get ruleActionProxy => 'Proxy';

  @override
  String get ruleActionDirect => 'Direct';

  @override
  String get ruleActionBlock => 'Block';

  @override
  String get webdavTitle => 'Cloud sync (WebDAV)';

  @override
  String get webdavDesc =>
      'Back up and sync your profiles to your own WebDAV cloud (Nextcloud, Koofr, box.com, …). Enter the full file URL. The password is stored locally on this device.';

  @override
  String get webdavUrlHint => 'https://dav.example.com/vpn/profiles.json';

  @override
  String get webdavUserLabel => 'Username';

  @override
  String get webdavPassLabel => 'Password';

  @override
  String get webdavBackup => 'Back up';

  @override
  String get webdavRestore => 'Restore';

  @override
  String get webdavBackedUp => 'Profiles backed up to cloud';

  @override
  String get syncError => 'Sync error';

  @override
  String get brutalTitle => 'Hysteria2 speed (Brutal)';

  @override
  String get brutalDesc =>
      'Enter your real connection speed so Hysteria2 holds throughput under packet loss. Leave blank for auto. Only affects Hysteria2 servers.';

  @override
  String get brutalDown => 'Download, Mbps';

  @override
  String get brutalUp => 'Upload, Mbps';

  @override
  String get brutalHint => 'auto';

  @override
  String get dnsTitle => 'Custom DNS (DoH)';

  @override
  String get dnsDesc =>
      'DNS-over-HTTPS resolver for all lookups. Leave blank for the default (Yandex 77.88.8.8, always reachable in RU). Use a server you trust — a blocked one just breaks name resolution.';

  @override
  String get dnsHint => 'e.g. 1.1.1.1 or dns.google';

  @override
  String get dnsInvalid =>
      'Enter a DNS server address — an IP or host, not a URL.';

  @override
  String get dnsApplyHint => 'Press Enter to apply while connected.';

  @override
  String get killSwitchTitle => 'Block on drop (TUN)';

  @override
  String get killSwitchDesc =>
      'In TUN mode, install a firewall fence (Windows Filtering Platform) that blocks ALL traffic except the tunnel if the core dies — no plaintext leak during reconnect. Auto-removed if the app exits, so it can\'t lock you out. Experimental: battle-test before relying on it.';

  @override
  String get settingsAdvanced => 'Advanced';

  @override
  String get settingsAdvancedHint =>
      'Tuned automatically for Russia — most users never need to touch these.';

  @override
  String get logLevelTitle => 'Logging';

  @override
  String get logLevelDesc =>
      'How much detail the in-app log shows (Activity → Logs). Warn = quiet (only warnings/errors), Info = every connection, Debug = everything.';
}
