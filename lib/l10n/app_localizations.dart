import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart' as intl;

import 'app_localizations_en.dart';
import 'app_localizations_ru.dart';

// ignore_for_file: type=lint

/// Callers can lookup localized strings with an instance of AppLocalizations
/// returned by `AppLocalizations.of(context)`.
///
/// Applications need to include `AppLocalizations.delegate()` in their app's
/// `localizationDelegates` list, and the locales they support in the app's
/// `supportedLocales` list. For example:
///
/// ```dart
/// import 'l10n/app_localizations.dart';
///
/// return MaterialApp(
///   localizationsDelegates: AppLocalizations.localizationsDelegates,
///   supportedLocales: AppLocalizations.supportedLocales,
///   home: MyApplicationHome(),
/// );
/// ```
///
/// ## Update pubspec.yaml
///
/// Please make sure to update your pubspec.yaml to include the following
/// packages:
///
/// ```yaml
/// dependencies:
///   # Internationalization support.
///   flutter_localizations:
///     sdk: flutter
///   intl: any # Use the pinned version from flutter_localizations
///
///   # Rest of dependencies
/// ```
///
/// ## iOS Applications
///
/// iOS applications define key application metadata, including supported
/// locales, in an Info.plist file that is built into the application bundle.
/// To configure the locales supported by your app, you’ll need to edit this
/// file.
///
/// First, open your project’s ios/Runner.xcworkspace Xcode workspace file.
/// Then, in the Project Navigator, open the Info.plist file under the Runner
/// project’s Runner folder.
///
/// Next, select the Information Property List item, select Add Item from the
/// Editor menu, then select Localizations from the pop-up menu.
///
/// Select and expand the newly-created Localizations item then, for each
/// locale your application supports, add a new item and select the locale
/// you wish to add from the pop-up menu in the Value field. This list should
/// be consistent with the languages listed in the AppLocalizations.supportedLocales
/// property.
abstract class AppLocalizations {
  AppLocalizations(String locale)
    : localeName = intl.Intl.canonicalizedLocale(locale.toString());

  final String localeName;

  static AppLocalizations of(BuildContext context) {
    return Localizations.of<AppLocalizations>(context, AppLocalizations)!;
  }

  static const LocalizationsDelegate<AppLocalizations> delegate =
      _AppLocalizationsDelegate();

  /// A list of this localizations delegate along with the default localizations
  /// delegates.
  ///
  /// Returns a list of localizations delegates containing this delegate along with
  /// GlobalMaterialLocalizations.delegate, GlobalCupertinoLocalizations.delegate,
  /// and GlobalWidgetsLocalizations.delegate.
  ///
  /// Additional delegates can be added by appending to this list in
  /// MaterialApp. This list does not have to be used at all if a custom list
  /// of delegates is preferred or required.
  static const List<LocalizationsDelegate<dynamic>> localizationsDelegates =
      <LocalizationsDelegate<dynamic>>[
        delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
      ];

  /// A list of this localizations delegate's supported locales.
  static const List<Locale> supportedLocales = <Locale>[
    Locale('en'),
    Locale('ru'),
  ];

  /// No description provided for @appTitle.
  ///
  /// In en, this message translates to:
  /// **'VPN App'**
  String get appTitle;

  /// No description provided for @navHome.
  ///
  /// In en, this message translates to:
  /// **'Home'**
  String get navHome;

  /// No description provided for @navActivity.
  ///
  /// In en, this message translates to:
  /// **'Activity'**
  String get navActivity;

  /// No description provided for @navSettings.
  ///
  /// In en, this message translates to:
  /// **'Settings'**
  String get navSettings;

  /// No description provided for @tabConnections.
  ///
  /// In en, this message translates to:
  /// **'Connections'**
  String get tabConnections;

  /// No description provided for @tabLogs.
  ///
  /// In en, this message translates to:
  /// **'Logs'**
  String get tabLogs;

  /// No description provided for @coreSubtitle.
  ///
  /// In en, this message translates to:
  /// **'sing-box • Windows'**
  String get coreSubtitle;

  /// No description provided for @statusConnected.
  ///
  /// In en, this message translates to:
  /// **'Connected'**
  String get statusConnected;

  /// No description provided for @statusChecking.
  ///
  /// In en, this message translates to:
  /// **'Checking connection…'**
  String get statusChecking;

  /// No description provided for @statusConnecting.
  ///
  /// In en, this message translates to:
  /// **'Connecting…'**
  String get statusConnecting;

  /// No description provided for @statusDisconnecting.
  ///
  /// In en, this message translates to:
  /// **'Disconnecting…'**
  String get statusDisconnecting;

  /// No description provided for @statusDisconnected.
  ///
  /// In en, this message translates to:
  /// **'Disconnected'**
  String get statusDisconnected;

  /// No description provided for @statusError.
  ///
  /// In en, this message translates to:
  /// **'Error'**
  String get statusError;

  /// No description provided for @profiles.
  ///
  /// In en, this message translates to:
  /// **'Profiles'**
  String get profiles;

  /// No description provided for @profilesEmpty.
  ///
  /// In en, this message translates to:
  /// **'No servers yet. Paste a link, scan a QR, or open a file.'**
  String get profilesEmpty;

  /// No description provided for @clipboardOfferText.
  ///
  /// In en, this message translates to:
  /// **'A server link is on your clipboard'**
  String get clipboardOfferText;

  /// No description provided for @fastestServer.
  ///
  /// In en, this message translates to:
  /// **'Fastest: {tag}'**
  String fastestServer(String tag);

  /// No description provided for @noReachableServer.
  ///
  /// In en, this message translates to:
  /// **'No server is reachable from here'**
  String get noReachableServer;

  /// No description provided for @diagDesyncOfferText.
  ///
  /// In en, this message translates to:
  /// **'These sites are throttled by TLS-DPI — the server-less bypass can open them with no server.'**
  String get diagDesyncOfferText;

  /// No description provided for @diagDesyncOfferAction.
  ///
  /// In en, this message translates to:
  /// **'Enable server-less bypass'**
  String get diagDesyncOfferAction;

  /// No description provided for @diagDesyncOfferDone.
  ///
  /// In en, this message translates to:
  /// **'Server-less DPI bypass enabled'**
  String get diagDesyncOfferDone;

  /// No description provided for @renameAction.
  ///
  /// In en, this message translates to:
  /// **'Rename'**
  String get renameAction;

  /// No description provided for @renameInvalid.
  ///
  /// In en, this message translates to:
  /// **'Name is empty or already taken'**
  String get renameInvalid;

  /// No description provided for @hardNetworkCtaText.
  ///
  /// In en, this message translates to:
  /// **'Not connecting? Mobile operators block harder than Wi-Fi.'**
  String get hardNetworkCtaText;

  /// No description provided for @hardNetworkCtaAction.
  ///
  /// In en, this message translates to:
  /// **'Make it work'**
  String get hardNetworkCtaAction;

  /// No description provided for @hardNetworkCtaDone.
  ///
  /// In en, this message translates to:
  /// **'Hard-network mode on — reconnecting'**
  String get hardNetworkCtaDone;

  /// No description provided for @noProfile.
  ///
  /// In en, this message translates to:
  /// **'No profile'**
  String get noProfile;

  /// No description provided for @tapToAdd.
  ///
  /// In en, this message translates to:
  /// **'tap to add'**
  String get tapToAdd;

  /// No description provided for @core.
  ///
  /// In en, this message translates to:
  /// **'Core'**
  String get core;

  /// No description provided for @coreNotRunning.
  ///
  /// In en, this message translates to:
  /// **'sing-box (not running)'**
  String get coreNotRunning;

  /// No description provided for @localProxy.
  ///
  /// In en, this message translates to:
  /// **'Local proxy'**
  String get localProxy;

  /// No description provided for @upload.
  ///
  /// In en, this message translates to:
  /// **'Upload'**
  String get upload;

  /// No description provided for @download.
  ///
  /// In en, this message translates to:
  /// **'Download'**
  String get download;

  /// No description provided for @coreLogsTitle.
  ///
  /// In en, this message translates to:
  /// **'Core logs ({count})'**
  String coreLogsTitle(int count);

  /// No description provided for @copy.
  ///
  /// In en, this message translates to:
  /// **'Copy'**
  String get copy;

  /// No description provided for @copied.
  ///
  /// In en, this message translates to:
  /// **'Logs copied'**
  String get copied;

  /// No description provided for @empty.
  ///
  /// In en, this message translates to:
  /// **'Empty'**
  String get empty;

  /// No description provided for @btnLinkList.
  ///
  /// In en, this message translates to:
  /// **'Link / list'**
  String get btnLinkList;

  /// No description provided for @btnSubscriptionUrl.
  ///
  /// In en, this message translates to:
  /// **'Subscription URL'**
  String get btnSubscriptionUrl;

  /// No description provided for @btnFromClipboard.
  ///
  /// In en, this message translates to:
  /// **'From clipboard'**
  String get btnFromClipboard;

  /// No description provided for @btnFromFile.
  ///
  /// In en, this message translates to:
  /// **'From file'**
  String get btnFromFile;

  /// No description provided for @btnScanScreenQr.
  ///
  /// In en, this message translates to:
  /// **'Scan QR on screen'**
  String get btnScanScreenQr;

  /// No description provided for @btnExport.
  ///
  /// In en, this message translates to:
  /// **'Export profiles…'**
  String get btnExport;

  /// No description provided for @exportDone.
  ///
  /// In en, this message translates to:
  /// **'Profiles exported'**
  String get exportDone;

  /// No description provided for @addProfile.
  ///
  /// In en, this message translates to:
  /// **'Add profile'**
  String get addProfile;

  /// No description provided for @dlgImportTitle.
  ///
  /// In en, this message translates to:
  /// **'Link or subscription'**
  String get dlgImportTitle;

  /// No description provided for @dlgImportHint.
  ///
  /// In en, this message translates to:
  /// **'vless://…  (multiple lines or base64 too)'**
  String get dlgImportHint;

  /// No description provided for @cancel.
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get cancel;

  /// No description provided for @importAction.
  ///
  /// In en, this message translates to:
  /// **'Import'**
  String get importAction;

  /// No description provided for @dlgUrlTitle.
  ///
  /// In en, this message translates to:
  /// **'Subscription by URL'**
  String get dlgUrlTitle;

  /// No description provided for @dlgUrlHint.
  ///
  /// In en, this message translates to:
  /// **'https://…'**
  String get dlgUrlHint;

  /// No description provided for @loadAction.
  ///
  /// In en, this message translates to:
  /// **'Load'**
  String get loadAction;

  /// No description provided for @msgAddedNodes.
  ///
  /// In en, this message translates to:
  /// **'Added {count} nodes'**
  String msgAddedNodes(int count);

  /// No description provided for @switchedTo.
  ///
  /// In en, this message translates to:
  /// **'Switched to {member}'**
  String switchedTo(String member);

  /// No description provided for @msgNotRecognized.
  ///
  /// In en, this message translates to:
  /// **'No nodes recognized'**
  String get msgNotRecognized;

  /// No description provided for @msgQrNotFound.
  ///
  /// In en, this message translates to:
  /// **'No QR code found in the image'**
  String get msgQrNotFound;

  /// No description provided for @msgSubscriptionEmpty.
  ///
  /// In en, this message translates to:
  /// **'Subscription is empty'**
  String get msgSubscriptionEmpty;

  /// No description provided for @msgClipboardEmpty.
  ///
  /// In en, this message translates to:
  /// **'No nodes in clipboard'**
  String get msgClipboardEmpty;

  /// No description provided for @msgAlreadyImported.
  ///
  /// In en, this message translates to:
  /// **'Already imported — reconnecting'**
  String get msgAlreadyImported;

  /// No description provided for @msgLoadError.
  ///
  /// In en, this message translates to:
  /// **'Load error: {error}'**
  String msgLoadError(String error);

  /// No description provided for @modeGlobal.
  ///
  /// In en, this message translates to:
  /// **'Global'**
  String get modeGlobal;

  /// No description provided for @modeSmart.
  ///
  /// In en, this message translates to:
  /// **'Smart'**
  String get modeSmart;

  /// No description provided for @modeGlobalDesc.
  ///
  /// In en, this message translates to:
  /// **'All traffic through proxy'**
  String get modeGlobalDesc;

  /// No description provided for @modeSmartDesc.
  ///
  /// In en, this message translates to:
  /// **'RU & local direct, rest through proxy'**
  String get modeSmartDesc;

  /// No description provided for @language.
  ///
  /// In en, this message translates to:
  /// **'Language'**
  String get language;

  /// No description provided for @languageSystem.
  ///
  /// In en, this message translates to:
  /// **'System'**
  String get languageSystem;

  /// No description provided for @about.
  ///
  /// In en, this message translates to:
  /// **'About'**
  String get about;

  /// No description provided for @version.
  ///
  /// In en, this message translates to:
  /// **'Version'**
  String get version;

  /// No description provided for @developer.
  ///
  /// In en, this message translates to:
  /// **'Developer'**
  String get developer;

  /// No description provided for @sourceCode.
  ///
  /// In en, this message translates to:
  /// **'Source code (GitHub)'**
  String get sourceCode;

  /// No description provided for @factsFeed.
  ///
  /// In en, this message translates to:
  /// **'Censorship facts'**
  String get factsFeed;

  /// No description provided for @factsFeedBuiltIn.
  ///
  /// In en, this message translates to:
  /// **'Built-in (updates on connect)'**
  String get factsFeedBuiltIn;

  /// No description provided for @vpnModeTitle.
  ///
  /// In en, this message translates to:
  /// **'VPN mode'**
  String get vpnModeTitle;

  /// No description provided for @antiDpiTitle.
  ///
  /// In en, this message translates to:
  /// **'Anti-DPI (TLS fragment)'**
  String get antiDpiTitle;

  /// No description provided for @antiDpiDesc.
  ///
  /// In en, this message translates to:
  /// **'Fragments the TLS handshake to beat SNI-based DPI. Slightly slower.'**
  String get antiDpiDesc;

  /// No description provided for @maxResistTitle.
  ///
  /// In en, this message translates to:
  /// **'Hard-network mode (mobile operator)'**
  String get maxResistTitle;

  /// No description provided for @maxResistDesc.
  ///
  /// In en, this message translates to:
  /// **'Mobile networks block far harder than Wi-Fi. Forces TLS fragmentation ON and keeps the survivor-preferring cascade active, regardless of the other switches. Turn on when it works on Wi-Fi but not on mobile.'**
  String get maxResistDesc;

  /// No description provided for @desyncTitle.
  ///
  /// In en, this message translates to:
  /// **'Unblock without a server'**
  String get desyncTitle;

  /// No description provided for @desyncDesc.
  ///
  /// In en, this message translates to:
  /// **'A packet-level engine that rewrites the outgoing TLS handshake so the censor can\'t read the site name (SNI) — unblocks throttled / TLS-DPI sites (YouTube, Discord, Rutracker…) with NO server. Needs administrator (loads a network driver). Doesn\'t help IP-blocked sites (Telegram, X) — those still need a server.'**
  String get desyncDesc;

  /// No description provided for @desyncActive.
  ///
  /// In en, this message translates to:
  /// **'DPI bypass active'**
  String get desyncActive;

  /// No description provided for @desyncNeedsAdmin.
  ///
  /// In en, this message translates to:
  /// **'Needs administrator — restart elevated to load the bypass driver.'**
  String get desyncNeedsAdmin;

  /// No description provided for @desyncMissing.
  ///
  /// In en, this message translates to:
  /// **'Engine not installed — put winws.exe + WinDivert in core\\windows.'**
  String get desyncMissing;

  /// No description provided for @desyncIdle.
  ///
  /// In en, this message translates to:
  /// **'Engages when you connect.'**
  String get desyncIdle;

  /// No description provided for @desyncTryNext.
  ///
  /// In en, this message translates to:
  /// **'Try next method'**
  String get desyncTryNext;

  /// No description provided for @desyncTryingNext.
  ///
  /// In en, this message translates to:
  /// **'Trying the next bypass method — check if the site opens now'**
  String get desyncTryingNext;

  /// No description provided for @desyncNoMore.
  ///
  /// In en, this message translates to:
  /// **'Tried every method — this site is likely IP-blocked (needs a server, not just desync)'**
  String get desyncNoMore;

  /// No description provided for @desyncStrategyLabel.
  ///
  /// In en, this message translates to:
  /// **'Method'**
  String get desyncStrategyLabel;

  /// No description provided for @desyncStratFakeSplit.
  ///
  /// In en, this message translates to:
  /// **'Split+fake'**
  String get desyncStratFakeSplit;

  /// No description provided for @desyncStratFakeDisorder.
  ///
  /// In en, this message translates to:
  /// **'Disorder'**
  String get desyncStratFakeDisorder;

  /// No description provided for @desyncStratSplit.
  ///
  /// In en, this message translates to:
  /// **'Split'**
  String get desyncStratSplit;

  /// No description provided for @autoFailoverTitle.
  ///
  /// In en, this message translates to:
  /// **'Auto-failover'**
  String get autoFailoverTitle;

  /// No description provided for @autoFailoverDesc.
  ///
  /// In en, this message translates to:
  /// **'urltest over all nodes: fastest working one, auto-switch when blocked.'**
  String get autoFailoverDesc;

  /// No description provided for @restartAsAdmin.
  ///
  /// In en, this message translates to:
  /// **'Restart as administrator'**
  String get restartAsAdmin;

  /// No description provided for @refreshSubs.
  ///
  /// In en, this message translates to:
  /// **'Refresh subscriptions'**
  String get refreshSubs;

  /// No description provided for @pingAll.
  ///
  /// In en, this message translates to:
  /// **'Measure latency (no connection)'**
  String get pingAll;

  /// No description provided for @pingAllWhileOn.
  ///
  /// In en, this message translates to:
  /// **'Measure before connecting — live latency is in Activity → Policies'**
  String get pingAllWhileOn;

  /// No description provided for @pinCertAction.
  ///
  /// In en, this message translates to:
  /// **'Pin certificate'**
  String get pinCertAction;

  /// No description provided for @pinCertTitle.
  ///
  /// In en, this message translates to:
  /// **'Pin server certificate'**
  String get pinCertTitle;

  /// No description provided for @pinCertHint.
  ///
  /// In en, this message translates to:
  /// **'Paste the server\'s certificate (PEM, -----BEGIN CERTIFICATE-----…)'**
  String get pinCertHint;

  /// No description provided for @pinCertDone.
  ///
  /// In en, this message translates to:
  /// **'Certificate pinned — verification is on, no longer insecure'**
  String get pinCertDone;

  /// No description provided for @pinCertInvalid.
  ///
  /// In en, this message translates to:
  /// **'That isn\'t a valid PEM certificate'**
  String get pinCertInvalid;

  /// No description provided for @pinCertMulti.
  ///
  /// In en, this message translates to:
  /// **'This config has several insecure servers — per-server pinning isn\'t supported yet'**
  String get pinCertMulti;

  /// No description provided for @unpinCertAction.
  ///
  /// In en, this message translates to:
  /// **'Remove pinned certificate'**
  String get unpinCertAction;

  /// No description provided for @unpinCertConfirm.
  ///
  /// In en, this message translates to:
  /// **'Remove the pinned certificate? The server goes back to no-verification (insecure) until you pin the correct one.'**
  String get unpinCertConfirm;

  /// No description provided for @unpinCertDone.
  ///
  /// In en, this message translates to:
  /// **'Pinned certificate removed'**
  String get unpinCertDone;

  /// No description provided for @pinnedBadge.
  ///
  /// In en, this message translates to:
  /// **'verified'**
  String get pinnedBadge;

  /// No description provided for @subsUpToDate.
  ///
  /// In en, this message translates to:
  /// **'Subscriptions up to date'**
  String get subsUpToDate;

  /// No description provided for @createOwnNode.
  ///
  /// In en, this message translates to:
  /// **'Create your own node'**
  String get createOwnNode;

  /// No description provided for @routingMode.
  ///
  /// In en, this message translates to:
  /// **'Routing mode'**
  String get routingMode;

  /// No description provided for @vpnModeProxy.
  ///
  /// In en, this message translates to:
  /// **'Proxy'**
  String get vpnModeProxy;

  /// No description provided for @vpnModeTun.
  ///
  /// In en, this message translates to:
  /// **'TUN'**
  String get vpnModeTun;

  /// No description provided for @vpnModeProxyDesc.
  ///
  /// In en, this message translates to:
  /// **'Only browsers and proxy-aware apps go through the tunnel — no admin needed. Other apps and their DNS go DIRECT (real IP exposed). For full protection use TUN mode.'**
  String get vpnModeProxyDesc;

  /// No description provided for @proxyAppsHint.
  ///
  /// In en, this message translates to:
  /// **'Apps that ignore the system proxy — Telegram desktop & its calls, CLI tools — only ride the tunnel in TUN mode, OR point their own SOCKS5 proxy at the address below (Telegram: Settings → Advanced → Connection type → SOCKS5 — this carries calls too).'**
  String get proxyAppsHint;

  /// No description provided for @proxyAddrCopied.
  ///
  /// In en, this message translates to:
  /// **'Local proxy address copied'**
  String get proxyAddrCopied;

  /// No description provided for @vpnModeTunDesc.
  ///
  /// In en, this message translates to:
  /// **'All system traffic via a VPN adapter (every app, UDP). Needs administrator.'**
  String get vpnModeTunDesc;

  /// No description provided for @serverGenDesc.
  ///
  /// In en, this message translates to:
  /// **'Your own VPS → a clean IP that isn\'t on RKN lists + Reality masquerade as a real site = operator-proof.'**
  String get serverGenDesc;

  /// No description provided for @serverGenIp.
  ///
  /// In en, this message translates to:
  /// **'Your VPS IP'**
  String get serverGenIp;

  /// No description provided for @serverGenMasquerade.
  ///
  /// In en, this message translates to:
  /// **'Masquerade as {sni}'**
  String serverGenMasquerade(String sni);

  /// No description provided for @generating.
  ///
  /// In en, this message translates to:
  /// **'Generating…'**
  String get generating;

  /// No description provided for @generate.
  ///
  /// In en, this message translates to:
  /// **'Generate'**
  String get generate;

  /// No description provided for @serverGenStep1.
  ///
  /// In en, this message translates to:
  /// **'1. Setup script (paste on the VPS over SSH as root)'**
  String get serverGenStep1;

  /// No description provided for @serverGenStep2.
  ///
  /// In en, this message translates to:
  /// **'2. Add the client profile'**
  String get serverGenStep2;

  /// No description provided for @serverGenAdded.
  ///
  /// In en, this message translates to:
  /// **'Profiles added (Reality + Hysteria2). Deploy the server with the script and connect.'**
  String get serverGenAdded;

  /// No description provided for @noConnections.
  ///
  /// In en, this message translates to:
  /// **'No active connections'**
  String get noConnections;

  /// No description provided for @connectionsActive.
  ///
  /// In en, this message translates to:
  /// **'{count} active'**
  String connectionsActive(int count);

  /// No description provided for @viewConfig.
  ///
  /// In en, this message translates to:
  /// **'sing-box config'**
  String get viewConfig;

  /// No description provided for @dropToImport.
  ///
  /// In en, this message translates to:
  /// **'Drop a config, link, or QR to import'**
  String get dropToImport;

  /// No description provided for @onboardTitle.
  ///
  /// In en, this message translates to:
  /// **'Add your first server'**
  String get onboardTitle;

  /// No description provided for @onboardBody.
  ///
  /// In en, this message translates to:
  /// **'Drop a QR or config file, paste a share link, or open a file — then tap connect.'**
  String get onboardBody;

  /// No description provided for @setupTitle.
  ///
  /// In en, this message translates to:
  /// **'Choose your protection'**
  String get setupTitle;

  /// No description provided for @setupBody.
  ///
  /// In en, this message translates to:
  /// **'How should the VPN protect this PC? You can change this anytime in Settings.'**
  String get setupBody;

  /// No description provided for @setupTunTitle.
  ///
  /// In en, this message translates to:
  /// **'Full-device protection'**
  String get setupTunTitle;

  /// No description provided for @setupTunBody.
  ///
  /// In en, this message translates to:
  /// **'Routes every app through the tunnel — no DNS or IPv6 leaks. Asks for admin rights when connecting.'**
  String get setupTunBody;

  /// No description provided for @setupTunBadge.
  ///
  /// In en, this message translates to:
  /// **'Most secure'**
  String get setupTunBadge;

  /// No description provided for @setupProxyTitle.
  ///
  /// In en, this message translates to:
  /// **'App proxy'**
  String get setupProxyTitle;

  /// No description provided for @setupProxyBody.
  ///
  /// In en, this message translates to:
  /// **'Simpler and needs no admin, but only proxy-aware apps are covered — other traffic can go direct.'**
  String get setupProxyBody;

  /// No description provided for @setupProxyBadge.
  ///
  /// In en, this message translates to:
  /// **'Simple'**
  String get setupProxyBadge;

  /// No description provided for @delete.
  ///
  /// In en, this message translates to:
  /// **'Delete'**
  String get delete;

  /// No description provided for @deleteProfileConfirm.
  ///
  /// In en, this message translates to:
  /// **'Delete \"{name}\"?'**
  String deleteProfileConfirm(String name);

  /// No description provided for @measuring.
  ///
  /// In en, this message translates to:
  /// **'measuring…'**
  String get measuring;

  /// No description provided for @serverGenInvalidIp.
  ///
  /// In en, this message translates to:
  /// **'Enter a valid IP address'**
  String get serverGenInvalidIp;

  /// No description provided for @serverGenFailed.
  ///
  /// In en, this message translates to:
  /// **'Generation failed — check the core and try again'**
  String get serverGenFailed;

  /// No description provided for @importFailed.
  ///
  /// In en, this message translates to:
  /// **'Imported, but the tunnel did not come up with this profile'**
  String get importFailed;

  /// No description provided for @importNoTraffic.
  ///
  /// In en, this message translates to:
  /// **'Connected, but no traffic — this server may be unreachable'**
  String get importNoTraffic;

  /// No description provided for @importNotConnected.
  ///
  /// In en, this message translates to:
  /// **'Imported — not connected. Review it in the list.'**
  String get importNotConnected;

  /// No description provided for @importDiscarded.
  ///
  /// In en, this message translates to:
  /// **'Discarded'**
  String get importDiscarded;

  /// No description provided for @importReviewTitle.
  ///
  /// In en, this message translates to:
  /// **'Imported server'**
  String get importReviewTitle;

  /// No description provided for @importProtocol.
  ///
  /// In en, this message translates to:
  /// **'Protocol'**
  String get importProtocol;

  /// No description provided for @importServer.
  ///
  /// In en, this message translates to:
  /// **'Server'**
  String get importServer;

  /// No description provided for @importConfigProfile.
  ///
  /// In en, this message translates to:
  /// **'sing-box config'**
  String get importConfigProfile;

  /// No description provided for @importExit.
  ///
  /// In en, this message translates to:
  /// **'Default route'**
  String get importExit;

  /// No description provided for @importRoutesDirect.
  ///
  /// In en, this message translates to:
  /// **'This config sends all traffic DIRECT — no VPN protection'**
  String get importRoutesDirect;

  /// No description provided for @importConnectAction.
  ///
  /// In en, this message translates to:
  /// **'Connect'**
  String get importConnectAction;

  /// No description provided for @importExternalWarning.
  ///
  /// In en, this message translates to:
  /// **'This server came from an external link or QR code. A hostile server can see and tamper with all your traffic — connect only if you trust the source.'**
  String get importExternalWarning;

  /// No description provided for @importFetchTitle.
  ///
  /// In en, this message translates to:
  /// **'Download server list?'**
  String get importFetchTitle;

  /// No description provided for @importFetchBody.
  ///
  /// In en, this message translates to:
  /// **'{host} will receive your IP address and the app will load a server list it provides. Continue only if you trust this link.'**
  String importFetchBody(String host);

  /// No description provided for @importFetchInsecure.
  ///
  /// In en, this message translates to:
  /// **'This is an http:// (cleartext) link — the server list can be tampered with on the way. Prefer an https:// link.'**
  String get importFetchInsecure;

  /// No description provided for @importContinue.
  ///
  /// In en, this message translates to:
  /// **'Continue'**
  String get importContinue;

  /// No description provided for @errCoreMissing.
  ///
  /// In en, this message translates to:
  /// **'Core binary not found. Reinstall the app.'**
  String get errCoreMissing;

  /// No description provided for @errTunNeedsAdmin.
  ///
  /// In en, this message translates to:
  /// **'TUN mode needs administrator.\nSettings → VPN mode → Restart as administrator.'**
  String get errTunNeedsAdmin;

  /// No description provided for @errConfigRejected.
  ///
  /// In en, this message translates to:
  /// **'The core rejected the config:\n{detail}'**
  String errConfigRejected(String detail);

  /// No description provided for @errWriteFailed.
  ///
  /// In en, this message translates to:
  /// **'Could not write the config: {detail}'**
  String errWriteFailed(String detail);

  /// No description provided for @errLaunchFailed.
  ///
  /// In en, this message translates to:
  /// **'Could not start the core: {detail}'**
  String errLaunchFailed(String detail);

  /// No description provided for @errNoApi.
  ///
  /// In en, this message translates to:
  /// **'The core started but did not answer the Clash API.'**
  String get errNoApi;

  /// No description provided for @errReconnecting.
  ///
  /// In en, this message translates to:
  /// **'Connection lost — reconnecting (traffic blocked, no leak)…'**
  String get errReconnecting;

  /// No description provided for @errGaveUp.
  ///
  /// In en, this message translates to:
  /// **'Could not connect after several tries — check the profile or network.'**
  String get errGaveUp;

  /// No description provided for @errKillSwitchFailed.
  ///
  /// In en, this message translates to:
  /// **'Kill-switch is ON but the firewall fence could not be installed — not connecting unprotected. Run the app as administrator, or turn the kill-switch off in Settings.'**
  String get errKillSwitchFailed;

  /// No description provided for @errProxyFailed.
  ///
  /// In en, this message translates to:
  /// **'Could not set the system proxy — not connecting (apps would go direct, unprotected). Check Windows proxy/registry permissions.'**
  String get errProxyFailed;

  /// No description provided for @errXrayMissing.
  ///
  /// In en, this message translates to:
  /// **'This profile needs the xray bridge (xray.exe), which is missing from the install. Reinstall the app or restore xray.exe.'**
  String get errXrayMissing;

  /// No description provided for @updateAvailable.
  ///
  /// In en, this message translates to:
  /// **'Update available: {version}'**
  String updateAvailable(String version);

  /// No description provided for @updateNow.
  ///
  /// In en, this message translates to:
  /// **'Update'**
  String get updateNow;

  /// No description provided for @updateBannerHint.
  ///
  /// In en, this message translates to:
  /// **'Open the release page to download the new version.'**
  String get updateBannerHint;

  /// No description provided for @serverGenChainToggle.
  ///
  /// In en, this message translates to:
  /// **'Domestic-relay chain (2 VPS)'**
  String get serverGenChainToggle;

  /// No description provided for @serverGenChainDesc.
  ///
  /// In en, this message translates to:
  /// **'A Russian-cloud relay (fronts a real RU site) forwards to a foreign exit. ТСПУ sees only domestic RU-IP ↔ RU-SNI traffic — operator-proof.'**
  String get serverGenChainDesc;

  /// No description provided for @serverGenRelayIp.
  ///
  /// In en, this message translates to:
  /// **'RU relay VPS IP'**
  String get serverGenRelayIp;

  /// No description provided for @serverGenExitIp.
  ///
  /// In en, this message translates to:
  /// **'Foreign exit VPS IP'**
  String get serverGenExitIp;

  /// No description provided for @serverGenRelayScript.
  ///
  /// In en, this message translates to:
  /// **'1a. Relay setup (run on the RU VPS)'**
  String get serverGenRelayScript;

  /// No description provided for @serverGenExitScript.
  ///
  /// In en, this message translates to:
  /// **'1b. Exit setup (run on the foreign VPS)'**
  String get serverGenExitScript;

  /// No description provided for @serverGenChainAdded.
  ///
  /// In en, this message translates to:
  /// **'Chain profile added — connect; ТСПУ sees only domestic traffic.'**
  String get serverGenChainAdded;

  /// No description provided for @diagnostics.
  ///
  /// In en, this message translates to:
  /// **'Diagnostics'**
  String get diagnostics;

  /// No description provided for @diagRun.
  ///
  /// In en, this message translates to:
  /// **'Check my network'**
  String get diagRun;

  /// No description provided for @diagChecking.
  ///
  /// In en, this message translates to:
  /// **'Checking…'**
  String get diagChecking;

  /// No description provided for @diagControls.
  ///
  /// In en, this message translates to:
  /// **'Controls (should load in RF)'**
  String get diagControls;

  /// No description provided for @diagBlocked.
  ///
  /// In en, this message translates to:
  /// **'RKN-blocked (VPN should fix)'**
  String get diagBlocked;

  /// No description provided for @diagDirect.
  ///
  /// In en, this message translates to:
  /// **'Direct'**
  String get diagDirect;

  /// No description provided for @diagViaVpn.
  ///
  /// In en, this message translates to:
  /// **'Via VPN'**
  String get diagViaVpn;

  /// No description provided for @diagRescued.
  ///
  /// In en, this message translates to:
  /// **'VPN unblocks {count} of {total} blocked sites'**
  String diagRescued(int count, int total);

  /// No description provided for @diagConnectHint.
  ///
  /// In en, this message translates to:
  /// **'Connect the VPN to compare the “Via VPN” column.'**
  String get diagConnectHint;

  /// No description provided for @vOk.
  ///
  /// In en, this message translates to:
  /// **'OK'**
  String get vOk;

  /// No description provided for @vDnsPoisoned.
  ///
  /// In en, this message translates to:
  /// **'DNS poisoned'**
  String get vDnsPoisoned;

  /// No description provided for @vTlsDpi.
  ///
  /// In en, this message translates to:
  /// **'TLS DPI'**
  String get vTlsDpi;

  /// No description provided for @vTcpReset.
  ///
  /// In en, this message translates to:
  /// **'TCP reset'**
  String get vTcpReset;

  /// No description provided for @vTimeout.
  ///
  /// In en, this message translates to:
  /// **'Timeout'**
  String get vTimeout;

  /// No description provided for @vDown.
  ///
  /// In en, this message translates to:
  /// **'Down'**
  String get vDown;

  /// No description provided for @serverDiagRun.
  ///
  /// In en, this message translates to:
  /// **'Diagnose my server'**
  String get serverDiagRun;

  /// No description provided for @serverDiagTunHint.
  ///
  /// In en, this message translates to:
  /// **'Disconnect (or use proxy mode) to test — TUN captures the probe'**
  String get serverDiagTunHint;

  /// No description provided for @serverDiagHint.
  ///
  /// In en, this message translates to:
  /// **'Probes your selected server raw (bypassing the tunnel) to show where the connection breaks here — for when it works on Wi-Fi but not on mobile.'**
  String get serverDiagHint;

  /// No description provided for @serverDiagHeader.
  ///
  /// In en, this message translates to:
  /// **'My server(s)'**
  String get serverDiagHeader;

  /// No description provided for @serverDiagNone.
  ///
  /// In en, this message translates to:
  /// **'Select a server first.'**
  String get serverDiagNone;

  /// No description provided for @serverDiagCopy.
  ///
  /// In en, this message translates to:
  /// **'Copy report'**
  String get serverDiagCopy;

  /// No description provided for @serverDiagCopied.
  ///
  /// In en, this message translates to:
  /// **'Diagnostic report copied'**
  String get serverDiagCopied;

  /// No description provided for @svReachableL4.
  ///
  /// In en, this message translates to:
  /// **'reaches (L4 OK)'**
  String get svReachableL4;

  /// No description provided for @svServerBlocked.
  ///
  /// In en, this message translates to:
  /// **'IP/port blocked'**
  String get svServerBlocked;

  /// No description provided for @svWhitelist.
  ///
  /// In en, this message translates to:
  /// **'whitelist — foreign dark'**
  String get svWhitelist;

  /// No description provided for @svUdpInconclusive.
  ///
  /// In en, this message translates to:
  /// **'UDP — can\'t probe'**
  String get svUdpInconclusive;

  /// No description provided for @svDnsInconclusive.
  ///
  /// In en, this message translates to:
  /// **'DNS unclear — can\'t verify'**
  String get svDnsInconclusive;

  /// No description provided for @svOffline.
  ///
  /// In en, this message translates to:
  /// **'Offline'**
  String get svOffline;

  /// No description provided for @tlsFpTitle.
  ///
  /// In en, this message translates to:
  /// **'Browser fingerprint'**
  String get tlsFpTitle;

  /// No description provided for @tlsFpDesc.
  ///
  /// In en, this message translates to:
  /// **'Mimic this browser\'s TLS handshake. “random” rotates among real browsers each connection.'**
  String get tlsFpDesc;

  /// No description provided for @muxTitle.
  ///
  /// In en, this message translates to:
  /// **'Multiplex (mux)'**
  String get muxTitle;

  /// No description provided for @muxDesc.
  ///
  /// In en, this message translates to:
  /// **'Carry many streams over one TLS connection — fewer connections for DPI to fingerprint. Skipped on Vision/QUIC.'**
  String get muxDesc;

  /// No description provided for @subDaysLeft.
  ///
  /// In en, this message translates to:
  /// **'{days} d left'**
  String subDaysLeft(int days);

  /// No description provided for @subExpired.
  ///
  /// In en, this message translates to:
  /// **'expired'**
  String get subExpired;

  /// No description provided for @autoAdaptTitle.
  ///
  /// In en, this message translates to:
  /// **'Auto-adapt to blocking'**
  String get autoAdaptTitle;

  /// No description provided for @autoAdaptDesc.
  ///
  /// In en, this message translates to:
  /// **'If ТСПУ starts choking the live tunnel, automatically cycle the TLS fingerprint / fragmentation / mux until traffic flows again — no manual fiddling.'**
  String get autoAdaptDesc;

  /// No description provided for @errPortInUse.
  ///
  /// In en, this message translates to:
  /// **'Local port is busy — another copy of the app is running (maybe as administrator). Close it, then reconnect.'**
  String get errPortInUse;

  /// No description provided for @connectOnLaunchTitle.
  ///
  /// In en, this message translates to:
  /// **'Connect on launch'**
  String get connectOnLaunchTitle;

  /// No description provided for @connectOnLaunchDesc.
  ///
  /// In en, this message translates to:
  /// **'If the VPN was on when you closed the app, reconnect automatically the next time it opens.'**
  String get connectOnLaunchDesc;

  /// No description provided for @registerLinksTitle.
  ///
  /// In en, this message translates to:
  /// **'Open vpn:// links & configs with this app'**
  String get registerLinksTitle;

  /// No description provided for @registerLinksDesc.
  ///
  /// In en, this message translates to:
  /// **'Register vpn:// / sing-box:// links and add this app to the .json \"Open with\" list, so a clicked link or config imports here. No admin needed.'**
  String get registerLinksDesc;

  /// No description provided for @autostartTitle.
  ///
  /// In en, this message translates to:
  /// **'Launch at startup'**
  String get autostartTitle;

  /// No description provided for @autostartDesc.
  ///
  /// In en, this message translates to:
  /// **'Start the app when you sign in to Windows. No admin. In TUN mode the tunnel still needs admin, so pair this with proxy mode for a UAC-free start.'**
  String get autostartDesc;

  /// No description provided for @closeToTrayTitle.
  ///
  /// In en, this message translates to:
  /// **'Keep running in the tray on close'**
  String get closeToTrayTitle;

  /// No description provided for @closeToTrayDesc.
  ///
  /// In en, this message translates to:
  /// **'Closing the window hides it to the tray and keeps the tunnel running. Open it again from the tray icon, or right-click the icon → Quit to exit.'**
  String get closeToTrayDesc;

  /// No description provided for @errWireguardHandshake.
  ///
  /// In en, this message translates to:
  /// **'WireGuard handshake never completed — the tunnel connects but carries no traffic. The server may be down, or this is an AmneziaWG config: its obfuscation isn\'t supported by the core (which speaks plain WireGuard), and plain WireGuard is throttled in Russia. Use a VLESS+Reality or Hysteria2 node instead.'**
  String get errWireguardHandshake;

  /// No description provided for @insecureBadge.
  ///
  /// In en, this message translates to:
  /// **'no cert check'**
  String get insecureBadge;

  /// No description provided for @policies.
  ///
  /// In en, this message translates to:
  /// **'Policies'**
  String get policies;

  /// No description provided for @policiesEmpty.
  ///
  /// In en, this message translates to:
  /// **'This profile has no switchable groups.\nOnly multi-node configs (Selector / URLTest) have policies.'**
  String get policiesEmpty;

  /// No description provided for @policyAuto.
  ///
  /// In en, this message translates to:
  /// **'auto'**
  String get policyAuto;

  /// No description provided for @policyTestAll.
  ///
  /// In en, this message translates to:
  /// **'Test all'**
  String get policyTestAll;

  /// No description provided for @policyAlive.
  ///
  /// In en, this message translates to:
  /// **'Live nodes (answered the through-tunnel probe)'**
  String get policyAlive;

  /// No description provided for @policyTimeout.
  ///
  /// In en, this message translates to:
  /// **'timeout'**
  String get policyTimeout;

  /// No description provided for @policiesPreview.
  ///
  /// In en, this message translates to:
  /// **'Preview — connect to switch servers and measure ping.'**
  String get policiesPreview;

  /// No description provided for @speedTestRun.
  ///
  /// In en, this message translates to:
  /// **'Test'**
  String get speedTestRun;

  /// No description provided for @speedTestRetry.
  ///
  /// In en, this message translates to:
  /// **'Again'**
  String get speedTestRetry;

  /// No description provided for @speedTestHint.
  ///
  /// In en, this message translates to:
  /// **'Real throughput through the tunnel'**
  String get speedTestHint;

  /// No description provided for @speedTestConnect.
  ///
  /// In en, this message translates to:
  /// **'Connect to run a speed test'**
  String get speedTestConnect;

  /// No description provided for @speedTestDownloading.
  ///
  /// In en, this message translates to:
  /// **'Download…'**
  String get speedTestDownloading;

  /// No description provided for @speedTestUploading.
  ///
  /// In en, this message translates to:
  /// **'Upload…'**
  String get speedTestUploading;

  /// No description provided for @killSwitchActive.
  ///
  /// In en, this message translates to:
  /// **'Kill-switch on'**
  String get killSwitchActive;

  /// No description provided for @killSwitchUnprotected.
  ///
  /// In en, this message translates to:
  /// **'Kill-switch ON but NOT protected'**
  String get killSwitchUnprotected;

  /// No description provided for @proxyModeLeakHint.
  ///
  /// In en, this message translates to:
  /// **'Proxy mode — apps that ignore the system proxy go direct'**
  String get proxyModeLeakHint;

  /// No description provided for @whitelistModeTitle.
  ///
  /// In en, this message translates to:
  /// **'Whitelist mode'**
  String get whitelistModeTitle;

  /// No description provided for @whitelistModeBody.
  ///
  /// In en, this message translates to:
  /// **'Your mobile network has been cut back to a state-approved allowlist — only Russian sites are reachable, no foreign exit works. This isn\'t a blocked node; use Wi-Fi or a domestic relay.'**
  String get whitelistModeBody;

  /// No description provided for @unblockHint.
  ///
  /// In en, this message translates to:
  /// **'The kill-switch blocked all traffic after the tunnel gave up.'**
  String get unblockHint;

  /// No description provided for @unblockAction.
  ///
  /// In en, this message translates to:
  /// **'Disconnect & unblock'**
  String get unblockAction;

  /// No description provided for @insecureConnectTitle.
  ///
  /// In en, this message translates to:
  /// **'Connect without certificate checks?'**
  String get insecureConnectTitle;

  /// No description provided for @insecureConnectBody.
  ///
  /// In en, this message translates to:
  /// **'This server turns off TLS certificate validation, so a network attacker could read or alter your traffic. Connect anyway?'**
  String get insecureConnectBody;

  /// No description provided for @insecureConnectAction.
  ///
  /// In en, this message translates to:
  /// **'Connect anyway'**
  String get insecureConnectAction;

  /// No description provided for @splitTunnelTitle.
  ///
  /// In en, this message translates to:
  /// **'Per-app routing (TUN)'**
  String get splitTunnelTitle;

  /// No description provided for @splitTunnelDesc.
  ///
  /// In en, this message translates to:
  /// **'Route specific processes per-app. DIRECT bypasses the VPN — only for apps that work WITHOUT one and want low ping (e.g. a game on RU servers). THROUGH VPN pins a blocked app (Discord, blocked games) to the tunnel so it always works. Add the exact .exe name.'**
  String get splitTunnelDesc;

  /// No description provided for @splitDirectLabel.
  ///
  /// In en, this message translates to:
  /// **'Direct (bypass VPN)'**
  String get splitDirectLabel;

  /// No description provided for @splitVpnLabel.
  ///
  /// In en, this message translates to:
  /// **'Force through VPN'**
  String get splitVpnLabel;

  /// No description provided for @splitTunnelHint.
  ///
  /// In en, this message translates to:
  /// **'process.exe'**
  String get splitTunnelHint;

  /// No description provided for @splitCommonApps.
  ///
  /// In en, this message translates to:
  /// **'Common apps:'**
  String get splitCommonApps;

  /// No description provided for @splitTunnelEmpty.
  ///
  /// In en, this message translates to:
  /// **'None'**
  String get splitTunnelEmpty;

  /// No description provided for @tunOnlyHint.
  ///
  /// In en, this message translates to:
  /// **'Works only in TUN mode.'**
  String get tunOnlyHint;

  /// No description provided for @customRulesTitle.
  ///
  /// In en, this message translates to:
  /// **'Custom routing rules'**
  String get customRulesTitle;

  /// No description provided for @customRulesDesc.
  ///
  /// In en, this message translates to:
  /// **'Force specific destinations through the tunnel, keep them direct, or block them. These win over Smart routing. Match a domain (and its sub-domains), an exact host, or an IP/CIDR.'**
  String get customRulesDesc;

  /// No description provided for @customRulesEmpty.
  ///
  /// In en, this message translates to:
  /// **'No rules — Smart routing decides everything'**
  String get customRulesEmpty;

  /// No description provided for @customRulesValueHint.
  ///
  /// In en, this message translates to:
  /// **'openai.com  or  1.2.3.4/24'**
  String get customRulesValueHint;

  /// No description provided for @transportBlockedWarn.
  ///
  /// In en, this message translates to:
  /// **'This transport (e.g. plain WireGuard / Shadowsocks) is widely blocked in Russia — prefer Reality, Hysteria2 or XHTTP.'**
  String get transportBlockedWarn;

  /// No description provided for @amneziaNoBridge.
  ///
  /// In en, this message translates to:
  /// **'AmneziaWG config — but the AmneziaWG bridge (awg.exe) isn\'t installed, so this falls back to plain WireGuard, which an Amnezia server rejects (it won\'t connect). A normal WireGuard .conf works as-is.'**
  String get amneziaNoBridge;

  /// No description provided for @fakeIpTitle.
  ///
  /// In en, this message translates to:
  /// **'Faster DNS (TUN)'**
  String get fakeIpTitle;

  /// No description provided for @fakeIpDesc.
  ///
  /// In en, this message translates to:
  /// **'Answer apps instantly with a placeholder address and resolve the real one at the exit — cuts first-load lag in TUN mode and avoids DNS leaks. Experimental; turn off if a site won\'t open.'**
  String get fakeIpDesc;

  /// No description provided for @advancedTitle.
  ///
  /// In en, this message translates to:
  /// **'Expert transport'**
  String get advancedTitle;

  /// No description provided for @advancedDesc.
  ///
  /// In en, this message translates to:
  /// **'Expert transport knobs. Leave default unless you know you need them.'**
  String get advancedDesc;

  /// No description provided for @tunStackTitle.
  ///
  /// In en, this message translates to:
  /// **'TUN network stack'**
  String get tunStackTitle;

  /// No description provided for @tunStackDesc.
  ///
  /// In en, this message translates to:
  /// **'gVisor is the safe default; system/mixed lower overhead but lean on the OS stack.'**
  String get tunStackDesc;

  /// No description provided for @muxProtoTitle.
  ///
  /// In en, this message translates to:
  /// **'Multiplex protocol (needs multiplex on)'**
  String get muxProtoTitle;

  /// No description provided for @muxPaddingTitle.
  ///
  /// In en, this message translates to:
  /// **'Multiplex padding'**
  String get muxPaddingTitle;

  /// No description provided for @muxPaddingDesc.
  ///
  /// In en, this message translates to:
  /// **'Pad multiplexed streams to hide their sizes.'**
  String get muxPaddingDesc;

  /// No description provided for @echTitle.
  ///
  /// In en, this message translates to:
  /// **'Encrypted ClientHello (ECH)'**
  String get echTitle;

  /// No description provided for @echDesc.
  ///
  /// In en, this message translates to:
  /// **'Hide the TLS server name on non-Reality nodes. Needs server ECH support — turn off if a node won\'t connect.'**
  String get echDesc;

  /// No description provided for @ecsTitle.
  ///
  /// In en, this message translates to:
  /// **'DNS Client Subnet (ECS)'**
  String get ecsTitle;

  /// No description provided for @ecsDesc.
  ///
  /// In en, this message translates to:
  /// **'Send resolvers a subnet for better CDN locality. Empty = off.'**
  String get ecsDesc;

  /// No description provided for @ecsHint.
  ///
  /// In en, this message translates to:
  /// **'e.g. 1.2.3.0/24'**
  String get ecsHint;

  /// No description provided for @ecsInvalid.
  ///
  /// In en, this message translates to:
  /// **'Invalid subnet — use a form like 1.2.3.0/24'**
  String get ecsInvalid;

  /// No description provided for @tfoTitle.
  ///
  /// In en, this message translates to:
  /// **'TCP Fast Open'**
  String get tfoTitle;

  /// No description provided for @tfoDesc.
  ///
  /// In en, this message translates to:
  /// **'Saves ~1 RTT on connect. Off by default — can break some servers and mobile-operator paths in Russia.'**
  String get tfoDesc;

  /// No description provided for @mptcpTitle.
  ///
  /// In en, this message translates to:
  /// **'Multipath TCP'**
  String get mptcpTitle;

  /// No description provided for @mptcpDesc.
  ///
  /// In en, this message translates to:
  /// **'Use multiple network paths when the server supports it. Advanced.'**
  String get mptcpDesc;

  /// No description provided for @shareImportTitle.
  ///
  /// In en, this message translates to:
  /// **'Imported shared setup'**
  String get shareImportTitle;

  /// No description provided for @shareApplySettings.
  ///
  /// In en, this message translates to:
  /// **'Apply the sender\'s protection settings'**
  String get shareApplySettings;

  /// No description provided for @shareApplySettingsDesc.
  ///
  /// In en, this message translates to:
  /// **'DPI bypass, per-app routing and rules from the share — only if you trust the sender.'**
  String get shareApplySettingsDesc;

  /// No description provided for @shareAutoUpdateNote.
  ///
  /// In en, this message translates to:
  /// **'This profile auto-updates from the sender\'s link.'**
  String get shareAutoUpdateNote;

  /// No description provided for @shareTitle.
  ///
  /// In en, this message translates to:
  /// **'Share'**
  String get shareTitle;

  /// No description provided for @shareForAnyClient.
  ///
  /// In en, this message translates to:
  /// **'For any app'**
  String get shareForAnyClient;

  /// No description provided for @shareForAnyClientDesc.
  ///
  /// In en, this message translates to:
  /// **'Standard links any VPN client can import — servers only, no settings.'**
  String get shareForAnyClientDesc;

  /// No description provided for @shareWithSettings.
  ///
  /// In en, this message translates to:
  /// **'With my settings'**
  String get shareWithSettings;

  /// No description provided for @shareWithSettingsDesc.
  ///
  /// In en, this message translates to:
  /// **'Our app only — also shares your DPI bypass + routing setup.'**
  String get shareWithSettingsDesc;

  /// No description provided for @shareCopied.
  ///
  /// In en, this message translates to:
  /// **'Link copied to clipboard'**
  String get shareCopied;

  /// No description provided for @shareCopyLink.
  ///
  /// In en, this message translates to:
  /// **'Copy link'**
  String get shareCopyLink;

  /// No description provided for @shareNothing.
  ///
  /// In en, this message translates to:
  /// **'Nothing to share yet — add a server first.'**
  String get shareNothing;

  /// No description provided for @shareNoUniversal.
  ///
  /// In en, this message translates to:
  /// **'These profiles are whole configs — standard links can\'t carry them. Use \"With my settings\" instead.'**
  String get shareNoUniversal;

  /// No description provided for @customRulesInvalid.
  ///
  /// In en, this message translates to:
  /// **'Invalid domain or IP — not added'**
  String get customRulesInvalid;

  /// No description provided for @customRulesLiveNote.
  ///
  /// In en, this message translates to:
  /// **'Changes apply immediately and briefly reconnect an active tunnel.'**
  String get customRulesLiveNote;

  /// No description provided for @ruleFieldDomainSuffix.
  ///
  /// In en, this message translates to:
  /// **'Domain'**
  String get ruleFieldDomainSuffix;

  /// No description provided for @ruleFieldDomain.
  ///
  /// In en, this message translates to:
  /// **'Exact host'**
  String get ruleFieldDomain;

  /// No description provided for @ruleFieldIpCidr.
  ///
  /// In en, this message translates to:
  /// **'IP / CIDR'**
  String get ruleFieldIpCidr;

  /// No description provided for @ruleActionProxy.
  ///
  /// In en, this message translates to:
  /// **'Proxy'**
  String get ruleActionProxy;

  /// No description provided for @ruleActionDirect.
  ///
  /// In en, this message translates to:
  /// **'Direct'**
  String get ruleActionDirect;

  /// No description provided for @ruleActionBlock.
  ///
  /// In en, this message translates to:
  /// **'Block'**
  String get ruleActionBlock;

  /// No description provided for @webdavTitle.
  ///
  /// In en, this message translates to:
  /// **'Cloud sync (WebDAV)'**
  String get webdavTitle;

  /// No description provided for @webdavDesc.
  ///
  /// In en, this message translates to:
  /// **'Back up and sync your profiles to your own WebDAV cloud (Nextcloud, Koofr, box.com, …). Enter the full file URL. The password is stored locally on this device.'**
  String get webdavDesc;

  /// No description provided for @webdavUrlHint.
  ///
  /// In en, this message translates to:
  /// **'https://dav.example.com/vpn/profiles.json'**
  String get webdavUrlHint;

  /// No description provided for @webdavUserLabel.
  ///
  /// In en, this message translates to:
  /// **'Username'**
  String get webdavUserLabel;

  /// No description provided for @webdavPassLabel.
  ///
  /// In en, this message translates to:
  /// **'Password'**
  String get webdavPassLabel;

  /// No description provided for @webdavBackup.
  ///
  /// In en, this message translates to:
  /// **'Back up'**
  String get webdavBackup;

  /// No description provided for @webdavRestore.
  ///
  /// In en, this message translates to:
  /// **'Restore'**
  String get webdavRestore;

  /// No description provided for @webdavBackedUp.
  ///
  /// In en, this message translates to:
  /// **'Profiles backed up to cloud'**
  String get webdavBackedUp;

  /// No description provided for @syncError.
  ///
  /// In en, this message translates to:
  /// **'Sync error'**
  String get syncError;

  /// No description provided for @brutalTitle.
  ///
  /// In en, this message translates to:
  /// **'Hysteria2 speed (Brutal)'**
  String get brutalTitle;

  /// No description provided for @brutalDesc.
  ///
  /// In en, this message translates to:
  /// **'Enter your real connection speed so Hysteria2 holds throughput under packet loss. Leave blank for auto. Only affects Hysteria2 servers.'**
  String get brutalDesc;

  /// No description provided for @brutalDown.
  ///
  /// In en, this message translates to:
  /// **'Download, Mbps'**
  String get brutalDown;

  /// No description provided for @brutalUp.
  ///
  /// In en, this message translates to:
  /// **'Upload, Mbps'**
  String get brutalUp;

  /// No description provided for @brutalHint.
  ///
  /// In en, this message translates to:
  /// **'auto'**
  String get brutalHint;

  /// No description provided for @dnsTitle.
  ///
  /// In en, this message translates to:
  /// **'Custom DNS (DoH)'**
  String get dnsTitle;

  /// No description provided for @dnsDesc.
  ///
  /// In en, this message translates to:
  /// **'DNS-over-HTTPS resolver for all lookups. Leave blank for the default (Yandex 77.88.8.8, always reachable in RU). Use a server you trust — a blocked one just breaks name resolution.'**
  String get dnsDesc;

  /// No description provided for @dnsHint.
  ///
  /// In en, this message translates to:
  /// **'e.g. 1.1.1.1 or dns.google'**
  String get dnsHint;

  /// No description provided for @dnsInvalid.
  ///
  /// In en, this message translates to:
  /// **'Enter a DNS server address — an IP or host, not a URL.'**
  String get dnsInvalid;

  /// No description provided for @dnsApplyHint.
  ///
  /// In en, this message translates to:
  /// **'Press Enter to apply while connected.'**
  String get dnsApplyHint;

  /// No description provided for @killSwitchTitle.
  ///
  /// In en, this message translates to:
  /// **'Block on drop (TUN)'**
  String get killSwitchTitle;

  /// No description provided for @killSwitchDesc.
  ///
  /// In en, this message translates to:
  /// **'In TUN mode, install a firewall fence (Windows Filtering Platform) that blocks ALL traffic except the tunnel if the core dies — no plaintext leak during reconnect. Auto-removed if the app exits, so it can\'t lock you out. Experimental: battle-test before relying on it.'**
  String get killSwitchDesc;

  /// No description provided for @settingsAdvanced.
  ///
  /// In en, this message translates to:
  /// **'Advanced'**
  String get settingsAdvanced;

  /// No description provided for @settingsAdvancedHint.
  ///
  /// In en, this message translates to:
  /// **'Tuned automatically for Russia — most users never need to touch these.'**
  String get settingsAdvancedHint;

  /// No description provided for @logLevelTitle.
  ///
  /// In en, this message translates to:
  /// **'Logging'**
  String get logLevelTitle;

  /// No description provided for @logLevelDesc.
  ///
  /// In en, this message translates to:
  /// **'How much detail the in-app log shows (Activity → Logs). Warn = quiet (only warnings/errors), Info = every connection, Debug = everything.'**
  String get logLevelDesc;
}

class _AppLocalizationsDelegate
    extends LocalizationsDelegate<AppLocalizations> {
  const _AppLocalizationsDelegate();

  @override
  Future<AppLocalizations> load(Locale locale) {
    return SynchronousFuture<AppLocalizations>(lookupAppLocalizations(locale));
  }

  @override
  bool isSupported(Locale locale) =>
      <String>['en', 'ru'].contains(locale.languageCode);

  @override
  bool shouldReload(_AppLocalizationsDelegate old) => false;
}

AppLocalizations lookupAppLocalizations(Locale locale) {
  // Lookup logic when only language code is specified.
  switch (locale.languageCode) {
    case 'en':
      return AppLocalizationsEn();
    case 'ru':
      return AppLocalizationsRu();
  }

  throw FlutterError(
    'AppLocalizations.delegate failed to load unsupported locale "$locale". This is likely '
    'an issue with the localizations generation tool. Please file an issue '
    'on GitHub with a reproducible sample app and the gen-l10n configuration '
    'that was used.',
  );
}
