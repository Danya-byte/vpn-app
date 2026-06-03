# vpn_app

A liquid-glass, censorship-resistant VPN client for Windows (cross-platform later),
built in Flutter on top of the **sing-box** core. Open-source, no telemetry.

> Status: active development, Windows desktop first. The app is a GUI + config engine over
> proven proxy cores — it does **not** reimplement protocols. The core path (import →
> generate → route system traffic) works and is schema- + traffic-verified.

## Features

- **Protocols** (via sing-box): VLESS + XTLS-Vision + Reality, Hysteria2, TUIC, Trojan,
  VMess, Shadowsocks, ShadowTLS, … (xray-core for XHTTP/mKCP is planned as a second engine).
- **Import anything**: share links (`vless/vmess/trojan/ss/hysteria2/tuic`), base64
  subscriptions, **full sing-box JSON configs** (run whole, auto-migrated to the 1.13 schema),
  and **Clash / Clash.Meta YAML**. Add via a link, a subscription URL, the clipboard, a native
  file picker, or **drag-and-drop** a config onto the window (frosted "drop to import" overlay).
  Re-importing de-dupes by content and reconnects; subscriptions refresh in one tap.
- **Routing into the OS**:
  - **System proxy** (no admin) — points Windows at the local inbound so browsers and
    proxy-aware apps go through the tunnel. Your existing proxy is backed up and restored.
  - **TUN** — a system-wide Wintun adapter (`auto_route`/`strict_route`) capturing *all*
    traffic incl. UDP. Needs admin; a one-tap "restart as administrator" elevates via UAC.
- **Anti-censorship by combination**:
  - **Auto-failover** — an `urltest` group over all your nodes picks the fastest working
    transport and fails over instantly when one is blocked.
  - **Anti-DPI** — fragments the TLS ClientHello to defeat SNI-based DPI (ТСПУ); always uTLS.
  - **Seamless reconnect** — re-establishes the tunnel on Wi-Fi/Ethernet/wake changes.
- **Speed out of the box**: Smart mode keeps RU + private traffic direct (not tunnelled),
  the rest through the proxy; split DNS (RU direct, foreign tunnelled).
- **Live dashboard**: active connections (host, chain, matched rule, per-conn traffic),
  totals and core logs via the Clash API; latency (ms) on Home; a raw-config viewer.
- **i18n**: English / Russian, auto-detected from the OS locale, manual override.
- **UI**: a "liquid glass" design — frosted panels, a draggable pill navbar, glass sheets/dialogs.

All native integration (OLE drag-and-drop, the system proxy, UAC elevation, the network-change
watch) lives in the Windows runner with **no plugins** — so no Developer Mode is required.

## Build (Windows)

Prerequisites: [Flutter](https://docs.flutter.dev/get-started/install/windows) (stable)
and Visual Studio 2022 with the *Desktop development with C++* workload.

```sh
# 1. fetch the proxy core binaries into core/windows/ (sing-box + wintun)
pwsh tool/fetch-cores.ps1            # add -IncludeXray once the xray bridge lands

# 2. run
flutter run -d windows
```

The core binaries are git-ignored; `fetch-cores.ps1` (re)populates them. The app has no
native plugins, so no special build flags (or Developer Mode) are required.

### Package & install

```sh
pwsh tool/package.ps1      # builds release (version/commit stamped), bundles cores +
                           # rule-sets + LICENSE/NOTICES, -> dist/vpn_app-windows-x64.zip
                           #   + a .sha256; signs every binary if VPNAPP_SIGN_PFX is set
iscc tool/installer.iss    # optional: a proper Inno Setup installer (shortcuts, autostart,
                           #   clean uninstall) -> dist/vpn_app-setup-<ver>.exe
```

The zip is extract-and-run — the cores sit next to `vpn_app.exe` and are resolved from there
(exe-relative first, so a stray `core\` in the launch directory can't shadow them).
System-proxy mode needs no admin; TUN mode prompts for elevation on demand.

## Project layout

```
lib/
  core/        config engine, share-link parser, core process manager, Clash API client
  features/    home · activity · settings · root (pages) + the profiles sheet
  widgets/     glass.dart — the reusable glass kit (GlassCard, GlassButton, GlassSurface,
               showGlassSheet, showGlassDialog, glassInputDecoration, GlassBackground)
  l10n/        ARB translations (en, ru) + generated AppLocalizations
core/windows/  bundled sing-box.exe + wintun.dll (git-ignored)
tool/          fetch-cores.ps1, gen.dart (dev helpers)
```

Architecture: the Flutter UI generates sing-box JSON from profiles and runs the core as a
managed child process; the UI talks to it over the Clash API. See
[CHANGELOG.md](CHANGELOG.md) for the milestone log.

## Verify your setup (no trust required)

`tool/verify_store.dart` is a **connection doctor** — it takes your real stored profile,
runs it through the exact app migration, validates it with the bundled core, and proves
live traffic actually flows through the tunnel:

```sh
dart run tool/verify_store.dart            # generate + sing-box check
dart run tool/verify_store.dart --connect  # + run the core, prove the exit IP differs,
                                           #   and that the Clash API rejects anon callers
```

## Security & supply chain

- **Fails closed, not open** — if the core dies or a transport is blocked, the app keeps your
  traffic pointed at the (now-dead) local proxy and auto-reconnects rather than silently
  falling back to the open internet; only a deliberate Stop restores your real system proxy.
  For full-device **TUN** mode an optional **WFP kill-switch fence** blocks *all* non-tunnel
  egress at the Windows firewall — it is **opt-in and experimental** (Settings → kill-switch);
  verify it on your own hardware before relying on it.
- **Pinned, verified cores** — `fetch-cores.ps1` pins exact core versions and checks each
  binary's **SHA-256** before installing it, so a poisoned mirror can't swap in a backdoor.
- **Local control plane is authenticated** — the Clash API is guarded by a random per-launch
  secret (no local app or web page can read your connections or switch your exit node).
- **No telemetry**, no phone-home. The update *check* (opt-in, GitHub releases) runs **through
  the tunnel**, so a stale build learns about a fix even where GitHub is blocked direct — but
  *downloading* it still needs the tunnel to cover your browser (TUN mode) or a mirror; a
  blocked-GitHub download page is a known distribution gap.
- Releases publish a `.sha256` next to the zip; sign your build by setting `VPNAPP_SIGN_PFX`
  (see `tool/package.ps1`) — an EV-signed binary clears SmartScreen and reduces AV friction.

## Roadmap to "best-of-the-best in RF"

Done: hardened kill-switch, secret-guarded API, atomic profile store, localized errors,
SHA-256-pinned cores, installer, version stamping, in-tunnel update check.
Remaining (tracked in CHANGELOG / M6): a signed **LocalSystem service** so TUN needs no
per-launch UAC and can autostart; one-click **auto-update apply** (today it surfaces the new
version + link); reproducible-build CI publishing signed artifacts + hashes.

## License

**GPL-3.0-or-later** (see [LICENSE](LICENSE)). The app bundles **sing-box** (GPL-3.0) and
**xray-core** (MPL-2.0); the combined distribution is GPL-3.0-or-later. Third-party
components and their licenses are listed in
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md); `tool/package.ps1` ships the full GPL text
(`COPYING.txt`) and notices inside every release archive. Open-source, no telemetry.
