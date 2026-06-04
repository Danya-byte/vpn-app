# vpn_app

**English** · [Русский](README.ru.md)

A liquid-glass, censorship-resistant VPN client for Windows (cross-platform later),
built in Flutter on top of the **sing-box** core (+ a bundled **xray** bridge for the
transports sing-box can't dial). Open-source, no telemetry. Tuned for Russia's ТСПУ DPI.

> Status: active development, Windows desktop first. The app is a GUI + config engine over
> proven proxy cores — it does **not** reimplement protocols. The core path (import →
> generate → route system traffic) works and is schema- + traffic-verified against the real
> binaries.

## What it can do

### Protocols & transports
Anything the bundled cores can dial, importable **and** runnable:
- **VLESS + XTLS-Vision + Reality** — uTLS-masquerades as a real allowlisted site, no own cert.
- **Hysteria2** (QUIC/UDP) with **Brutal** congestion control (constant bandwidth under ТСПУ loss).
- **TUIC v5**, **Trojan**, **VMess**, **Shadowsocks** (incl. 2022 ciphers), **AnyTLS**.
- **WireGuard**, and **AmneziaWG** obfuscation (Jc/Jmin/Jmax/S/H) via a userspace bridge
  (drop `core/windows/awg.exe`; absent → detected and skipped, never a fake "connected").
- **XHTTP / SplitHTTP** via a bundled **xray** bridge — the sub-16 KB-freeze transport sing-box
  can't do; plus **gRPC, WebSocket, HTTPUpgrade, HTTP/2**.

### Import anything
Share links (`vless/vmess/trojan/ss/hysteria2/tuic/anytls`), **base64 subscriptions**, full
**sing-box JSON** (run whole, auto-migrated to the current schema), **Clash / Clash.Meta YAML**,
and **WireGuard / AmneziaWG `.conf`** — added via a link, a **subscription URL** (auto-refresh
every 6 h + one-tap manual, with used/expiry from the panel header), the clipboard, a file picker,
**drag-and-drop**, a **QR code** (drop an image **or scan the screen** — no camera), or a
**deep link** (`vpn://` / `clash://` / `hiddify://` / `sing-box://`, both cold-launch and while
already running). A config from an untrusted source (drop / QR / deep link) is **previewed and
gated** before connecting — protocol, server, SNI, an *insecure* (no cert check) badge, and a loud
**"routes everything DIRECT"** warning for a config that would tunnel nothing.

### Anti-DPI & resilience (the ТСПУ core)
- **uTLS** with a selectable fingerprint pool (chrome / firefox / safari / edge / ios / yandex),
  applied to imported configs too; **TLS ClientHello fragmentation** to split the SNI; ECH plumbing.
- **Transport cascade** — when a path goes dark, auto-hops to a genuinely *different* transport
  family (Reality ↔ plain-TLS ↔ Hysteria2 ↔ XHTTP) by true signature.
- **16 KB foreign-IP "freeze"** detection — catches the throttle that *passes small requests but
  stalls big ones* and hops to a transport the freeze can't reach.
- **Whitelist-mode** detection — when the mobile network collapses to a state allowlist (only RU
  IPs reachable), it stays connected, latches an amber banner, and stops burning retries.
- Proactive hop on sustained **latency degradation** before a path is fully cut.
- **Live censorship-fact feed** — the throttled-domain list + freeze thresholds refresh *through
  the tunnel* on connect (data-only, signed-in-spirit, hard-clamped), so a new blocking wave is
  handled without an app update.
- **Auto-failover** across all your nodes; **seamless reconnect** on Wi-Fi/Ethernet/wake.

### Routing & DNS
- **Smart mode**: RU + private → direct, the rest → tunnel; sanctioned RU sites stay direct (so
  they don't reverse-geo-block your foreign exit); ad/tracker blocking on by default.
- **Per-app split-tunnel** — by process name, **bidirectional** (force an app *out* of the VPN, or
  *into* it), TUN mode.
- `urltest` auto-pick + manual selector groups, switchable live in the UI.
- **Bundled local rule-sets** (no startup GitHub fetch — that deadlocks the core in RF).
- **Split DNS** — foreign → DoH through the tunnel, RU → a direct resolver; forced IPv4 (RF has no
  reliable v6); DNS-leak fences; legacy configs' DNS auto-migrated to the current schema.

### Into the OS
- **System proxy** (no admin) — points Windows at the local inbound; your existing proxy is backed
  up and restored on disconnect/uninstall.
- **TUN** — a system-wide Wintun adapter (`auto_route`/`strict_route`, dual-stack capture) catching
  *all* traffic incl. UDP; needs admin (one-tap "restart as administrator").
- **WFP kill-switch** — a fail-closed Windows-firewall fence that blocks *all* non-tunnel egress so
  a dead/blocked tunnel can't leak. **Opt-in & experimental** — verify with `tool/leak-test.ps1` on
  your hardware before relying on it.

### Generate your own exit
In-app **ServerGen** makes a **VLESS + Reality (+ Hysteria2) server** config, the matching client
link, and a one-paste VPS setup script — even a **domestic-relay 2-hop chain** (a RU-cloud relay
fronting a big-RU SNI → a foreign exit), so the observed connection looks like ordinary domestic
traffic.

### Observe & control
Clash API + an in-app dashboard: live **connections** (host, outbound chain, *which rule matched*,
per-connection traffic), core logs, **per-server ping + "X of Y alive" pool health**, live policy
switching, a **connection Diagnostics** probe (DNS-poison / TLS-DPI / TCP-reset, direct vs through
the tunnel), and a real **Mbps speed test** through the tunnel.

### UX
Liquid-glass design; **one-tap connect** + one-tap mode switch; **honest status** — it shows
"Checking…" (not a fake green "Connected") when the tunnel is dark, and hides a stale ping/exit-IP;
first-run protection-mode chooser; system tray + close-to-tray + launch-at-startup; English /
Russian, auto-detected.

All native integration (OLE drag-and-drop, the system proxy, UAC elevation, the WFP fence, QR
screen-scan, the network-change watch, warm-start deep links) lives in the Windows runner with
**no Flutter plugins** — so no Developer Mode is required.

## Build (Windows)

Prerequisites: [Flutter](https://docs.flutter.dev/get-started/install/windows) (stable, Dart ≥ 3.12)
and Visual Studio 2022 with the *Desktop development with C++* workload.

```sh
# 1. fetch the SHA-256-pinned cores into core/windows/ (sing-box + xray + wintun) + rule-sets
pwsh tool/fetch-cores.ps1 -IncludeXray

# 2. run
flutter run -d windows
```

The core binaries + rule-sets are git-ignored; `fetch-cores.ps1` (re)populates them. The app has no
native plugins, so no special build flags (or Developer Mode) are required.
(AmneziaWG support additionally needs an Amnezia-aware `awg.exe` in `core/windows/`, fetched
separately — without it AmneziaWG nodes are detected and skipped.)

### Package & install

```sh
pwsh tool/package.ps1      # release build (version/commit stamped) → bundles cores + rule-sets +
                           # LICENSE/NOTICES → dist/vpn_app-windows-x64.zip + .sha256, and an
                           # Inno Setup installer (dist/vpn_app-setup-<ver>.exe) if iscc is found.
```

The zip is extract-and-run — the cores sit next to `vpn_app.exe` and are resolved exe-relative.
System-proxy mode needs no admin; TUN mode prompts for elevation on demand.

### Cut a release

CI publishes a GitHub Release when a push to `main` carries a **version marker in the commit
message** — `[v1.2]`, `[v1.2.3]`, or with a channel suffix `[v1.2 beta]` / `[v1.0.2-rc1]`
(a space becomes `-`: `[v1.2 beta]` → tag `v1.2-beta`). No git tag needed:

```sh
git commit -m "installer + RF hardening [v1.2 beta]"
git push origin main          # → CI: analyze + test → build zip + installer + .sha256
                              #   → creates tag v1.2-beta + the GitHub Release
```
A normal push (no `[v…]` marker) builds nothing. The marker's version is stamped into the build,
installer name, and About so they match the tag. (`.github/workflows/release.yml` also has a manual
`workflow_dispatch`.) Releases ship **unsigned** with a published `.sha256`.

## Project layout

```
lib/
  core/        config engine, share-link/clash/wireguard parsers, xray + AmneziaWG bridges,
               cascade/watchdog, censorship-fact feed, core process manager, Clash API client
  features/    home · activity · settings · root (pages) + the profiles sheet
  widgets/     glass.dart — the reusable glass kit
  l10n/        ARB translations (en, ru) + generated AppLocalizations
core/windows/  bundled sing-box.exe + xray.exe + wintun.dll (git-ignored)
core/rule-sets/ bundled geoip-ru / geosite-ru / geosite-ads .srs (git-ignored)
windows/runner/ C++ runner: WFP kill-switch, system proxy, drag-drop, tray, deep links
tool/          fetch-cores.ps1, package.ps1, installer.iss, leak-test.ps1, verify_store.dart, …
```

Architecture: the Flutter UI generates sing-box JSON from profiles and runs the core(s) as managed
child processes; the UI talks to it over the Clash API. Change log: [CHANGELOG.txt](CHANGELOG.txt).

## Verify your setup (no trust required)

`tool/verify_store.dart` is a **connection doctor** — it takes your real stored profile, runs it
through the exact app migration, validates it with the bundled core, and proves live traffic flows:

```sh
dart run tool/verify_store.dart            # generate + sing-box check
dart run tool/verify_store.dart --connect  # + run the core, prove the exit IP differs, and that
                                           #   the Clash API rejects anonymous callers
pwsh tool/leak-test.ps1                     # (admin, TUN + kill-switch ON) prove NO egress leaks
                                           #   on the physical NIC after a core crash, and that the
                                           #   fence drops on app close
```

## Security & supply chain

- **Fails closed, not open** — if the core dies or a transport is blocked, traffic stays pointed at
  the (now-dead) local proxy and auto-reconnects rather than falling back to the open internet; only
  a deliberate Stop restores your real system proxy. TUN mode adds the opt-in **WFP kill-switch
  fence** (verify on your hardware before relying on it).
- **Pinned, verified cores** — `fetch-cores.ps1` pins exact versions and checks each binary's
  **SHA-256** before installing, so a poisoned mirror can't swap in a backdoor.
- **Authenticated control plane** — the Clash API is guarded by a random per-launch secret.
- **No telemetry**, no phone-home. The update *check* (opt-in) runs through the tunnel so a stale
  build learns about a fix even where GitHub is blocked direct.
- **Hostile-import defense** — externally-supplied configs are previewed + consent-gated (never a
  one-click MITM); link/DNS/AmneziaWG fields are validated/sanitised on import.
- Releases ship **unsigned** with a published `.sha256` — the hash, against open-source inspectable
  builds, is the integrity check.

## Roadmap

Done: transport cascade + freeze/whitelist detection, anti-DPI fingerprint pool,
censorship-fact feed, per-app split-tunnel, ServerGen, in-app diagnostics/speed-test,
SHA-256-pinned cores, installer + commit-message release trigger, secret-guarded API, fail-closed
contract.
Remaining: on-hardware kill-switch leak verification (before defaulting it on); performance knobs
(TCP Fast Open / MPTCP / system TUN stack / mux variants); multi-port & port-hopping; hy2 cert
pinning; an ECS/FakeIP/ECH UI; an Android build.

## License

**GPL-3.0-or-later** (see [LICENSE](LICENSE)). The app bundles **sing-box** (GPL-3.0) and
**xray-core** (MPL-2.0); the combined distribution is GPL-3.0-or-later. Third-party components and
their licenses are listed in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md); `tool/package.ps1`
ships the full GPL text (`COPYING.txt`) and notices inside every release archive.
