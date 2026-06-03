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
  /// **'Empty. Paste a link or subscription below.'**
  String get profilesEmpty;

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

  /// No description provided for @openSourceNote.
  ///
  /// In en, this message translates to:
  /// **'Open source • no telemetry'**
  String get openSourceNote;

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

  /// No description provided for @onboardAdd.
  ///
  /// In en, this message translates to:
  /// **'Add a server'**
  String get onboardAdd;

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

  /// No description provided for @updateAvailable.
  ///
  /// In en, this message translates to:
  /// **'Update available: {version}'**
  String updateAvailable(String version);

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

  /// No description provided for @tlsFpTitle.
  ///
  /// In en, this message translates to:
  /// **'TLS fingerprint (uTLS)'**
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

  /// No description provided for @echTitle.
  ///
  /// In en, this message translates to:
  /// **'ECH — encrypt SNI'**
  String get echTitle;

  /// No description provided for @echDesc.
  ///
  /// In en, this message translates to:
  /// **'Encrypts the ClientHello so the SNI is fully hidden. Requires server-side ECH support.'**
  String get echDesc;

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

  /// No description provided for @desyncTitle.
  ///
  /// In en, this message translates to:
  /// **'Unblock without a server'**
  String get desyncTitle;

  /// No description provided for @desyncDesc.
  ///
  /// In en, this message translates to:
  /// **'With NO server selected, Connect runs a local DPI-desync that unblocks THROTTLED sites (YouTube, Discord) by fragmenting the TLS handshake — zero config, no server. IP-blocked sites (Instagram, X) still need a server.'**
  String get desyncDesc;

  /// No description provided for @desyncHint.
  ///
  /// In en, this message translates to:
  /// **'No server — tap Connect to unblock YouTube/Discord locally'**
  String get desyncHint;

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

  /// No description provided for @splitTunnelEmpty.
  ///
  /// In en, this message translates to:
  /// **'None'**
  String get splitTunnelEmpty;

  /// No description provided for @killSwitchTitle.
  ///
  /// In en, this message translates to:
  /// **'TUN kill-switch (experimental)'**
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
