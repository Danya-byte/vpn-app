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
  String get tabConnections => 'Connections';

  @override
  String get tabLogs => 'Logs';

  @override
  String get coreSubtitle => 'sing-box • Windows';

  @override
  String get statusConnected => 'Connected';

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
  String get profilesEmpty => 'Empty. Paste a link or subscription below.';

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
  String get openSourceNote => 'Open source • no telemetry';

  @override
  String get vpnModeTitle => 'VPN mode';

  @override
  String get antiDpiTitle => 'Anti-DPI (TLS fragment)';

  @override
  String get antiDpiDesc =>
      'Fragments the TLS handshake to beat SNI-based DPI. Slightly slower.';

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
  String get onboardAdd => 'Add a server';

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
  String get importReviewTitle => 'Imported server';

  @override
  String get importProtocol => 'Protocol';

  @override
  String get importServer => 'Server';

  @override
  String get importConfigProfile => 'sing-box config';

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
  String updateAvailable(String version) {
    return 'Update available: $version';
  }

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
  String get tlsFpTitle => 'TLS fingerprint (uTLS)';

  @override
  String get tlsFpDesc =>
      'Mimic this browser\'s TLS handshake. “random” rotates among real browsers each connection.';

  @override
  String get muxTitle => 'Multiplex (mux)';

  @override
  String get muxDesc =>
      'Carry many streams over one TLS connection — fewer connections for DPI to fingerprint. Skipped on Vision/QUIC.';

  @override
  String get echTitle => 'ECH — encrypt SNI';

  @override
  String get echDesc =>
      'Encrypts the ClientHello so the SNI is fully hidden. Requires server-side ECH support.';

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
  String get desyncTitle => 'Unblock without a server';

  @override
  String get desyncDesc =>
      'With NO server selected, Connect runs a local DPI-desync that unblocks THROTTLED sites (YouTube, Discord) by fragmenting the TLS handshake — zero config, no server. IP-blocked sites (Instagram, X) still need a server.';

  @override
  String get desyncHint =>
      'No server — tap Connect to unblock YouTube/Discord locally';

  @override
  String get killSwitchActive => 'Kill-switch on';

  @override
  String get killSwitchUnprotected => 'Kill-switch ON but NOT protected';

  @override
  String get proxyModeLeakHint =>
      'Proxy mode — apps that ignore the system proxy go direct';

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
  String get splitTunnelEmpty => 'None';

  @override
  String get killSwitchTitle => 'TUN kill-switch (experimental)';

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
