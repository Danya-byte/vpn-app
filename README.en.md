# vpn_app

[Русский](README.md) · **English**

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
- **Hysteria2** (QUIC/UDP) with **Brutal** congestion control (constant bandwidth under ТСПУ loss)
  and **multi-port / port-hopping** — rotates across a shared port range to dodge port-based throttling.
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
gated** before connecting — protocol, server, SNI, an *insecure* (no cert check) badge — which you
can clear by **pinning the server's TLS certificate** (paste it once; the connection is then verified
against exactly that cert, reversible in-app) — a loud
**"routes everything DIRECT"** warning for a config that would tunnel nothing, and a heads-up when
the server rides a transport that's **widely blocked in RF** (plain WireGuard / Shadowsocks). Your
whole profile set can also be **backed up / synced over WebDAV** (HTTPS, your own cloud) — one tap
to restore after a reinstall or onto a second device.

**Share your setup** (Profiles → ⋮ → Share). *For any client* makes standard links any VPN app can
import — it even pulls the individual servers out of a whole config. *With my settings* makes a
single `vpn://` link (or QR) that — in this app — carries your servers **plus** your DPI-bypass and
per-app routing, so a friend gets your whole working setup in one paste. The link is compact
(compressed), never includes your private data, and the recipient always **previews and consents**
before anything applies or connects.

### Anti-DPI & resilience (the ТСПУ core)
- **uTLS** with a selectable fingerprint pool (chrome / firefox / safari / edge / ios / yandex),
  applied to imported configs too; **TLS ClientHello fragmentation** to split the SNI.
- **Native ECH masquerade (the way Chrome does it)** — with ECH on, the app auto-discovers each node's
  DNS-published ECH key (over encrypted DoH) and **encrypts the real TLS server name** inside the
  handshake: only the cover `public_name` is on the wire (for a Cloudflare-fronted node, a Cloudflare
  name). No bespoke binary — the same edge proprietary "masquerade" VPNs get from a separate program,
  here on the stock core. Best for Cloudflare-fronted / your own ECH endpoint; on a plain node with no
  ECH it's a no-op (best-effort lookup, fails safe on timeout). Reality is left untouched (it hides its
  own name a different way).
- **Server-less DPI bypass (WinDivert)** — an optional zapret-class packet engine (`winws`) that
  desyncs the outgoing TLS ClientHello (fake decoy + split/disorder + TTL fooling) so ТСПУ can't
  read the SNI, unblocking throttled / TLS-DPI sites (YouTube, Discord, Rutracker…) with **no
  server at all**. Needs admin (loads a kernel driver) + the binary (fetched separately, like xray);
  doesn't help IP-blocked sites (Telegram, X — those still need a foreign exit). Switchable desync
  method presets so you can find what survives your operator. *Plain TLS fragmentation alone was
  dropped — ТСПУ reassembles it; this is the fake+disorder escalation that survives reassembly.*
- **Transport cascade** — when a path goes dark, auto-hops to a genuinely *different* transport
  family (Reality ↔ plain-TLS ↔ Hysteria2 ↔ XHTTP) by true signature, **preferring the transports
  that survive 2026-era blocking** (XHTTP-split / Hysteria2-QUIC / Reality) over the signature-blocked
  ones (plain VLESS / Shadowsocks / WireGuard).
- **16 KB foreign-IP "freeze"** detection — catches the throttle that *passes small requests but
  stalls big ones* and hops to a transport the freeze can't reach.
- **Whitelist-mode** detection — when the mobile network collapses to a state allowlist (only RU
  IPs reachable), it stays connected, latches an amber banner, and stops burning retries.
- **Hard-network (mobile-operator) mode** — for the "works on home Wi-Fi but not on mobile data"
  case: one tap forces TLS fragmentation on, keeps the survivor-preferring cascade active, and turns
  on auto-adapt — surfaced right when the tunnel goes dark, not buried in settings.
- **Native server-less Telegram unblock (`tgcore` engine)** — a bundled local MTProxy bridges Telegram
  to its *un-throttled web gateway* over a WebSocket masked as *your* browser's TLS (the fingerprint is
  captured once, automatically). Telegram — **messages AND media** — rides a clean path that looks like
  ordinary browser HTTPS, **with no foreign server**. Flip the toggle (Settings → Advanced → "Telegram
  without a server") and tap "Open in Telegram" — the proxy is added in one tap. The base needs no admin;
  the optional **Calls** switch adds a packet-level STUN desync (needs admin). Honest scope: it works
  *from inside* Russia (the un-throttled gateway is only clean under the filter), it's about reliability
  + media rather than raw speed, and a full regional IP shutdown still needs a server.
- **Via your own server (when even the gateway is IP-blocked)** — on connect the app **automatically**
  pins Telegram's published DC/relay CIDRs + domains to your foreign exit. **Messages** ride either mode;
  **calls** (UDP) need **TUN**. Tip: point Telegram's built-in **SOCKS5** at `127.0.0.1:2080` (Settings →
  Advanced → Use custom proxy → SOCKS5) — the app's local proxy listens there always (proxy and TUN), so
  Telegram routes itself through the tunnel for **both messages and calls**, independent of the app mode.
- Proactive hop on sustained **latency degradation** before a path is fully cut.
- **Live censorship-fact feed** — the throttled-domain list + freeze thresholds refresh *through
  the tunnel* on connect (data-only, signed-in-spirit, hard-clamped), so a new blocking wave is
  handled without an app update.
- **Auto-failover** across all your nodes; **seamless reconnect** on Wi-Fi/Ethernet/wake.

### Routing & DNS
- **Smart mode**: RU + private → direct, the rest → tunnel; sanctioned RU sites stay direct (so
  they don't reverse-geo-block your foreign exit); ad/tracker blocking on by default.
- **Custom routing rules** — force any domain (and its sub-domains), exact host, or IP/CIDR to
  **Proxy / Direct / Block**; your rules win over Smart mode, and apply live.
- **Per-app split-tunnel** — by process name, **bidirectional** (force an app *out* of the VPN, or
  *into* it), TUN mode. Pick the app from disk with a Browse button or a common-app preset
  (Telegram / Chrome / Discord / Steam …) — no need to know the exact `.exe`.
- `urltest` auto-pick + manual selector groups, switchable live in the UI.
- **Bundled local rule-sets** (no startup GitHub fetch — that deadlocks the core in RF).
- **Split DNS** — foreign → DoH through the tunnel, RU → a direct resolver; forced IPv4 (RF has no
  reliable v6); DNS-leak fences; legacy configs' DNS auto-migrated to the current schema.
- **Optional FakeIP** (TUN) — answers apps instantly with a placeholder address and resolves the
  real one at the exit: faster first-load, no DNS leak. Experimental, off by default.

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
the tunnel), a real **Mbps speed test** through the tunnel, and a **pre-connect latency probe** —
tap once (while disconnected) to colour-code every server's reachability + ping before you pick one
(resolves names over DoH so a poisoned answer can't fake a fast dead server).

### UX
Liquid-glass design; **one-tap connect** + one-tap mode switch; **honest status** — it shows
"Checking…" (not a fake green "Connected") when the tunnel is dark, and hides a stale ping/exit-IP;
a Home banner if you copied a server link; a deferred first-run protection-mode chooser (asked after
your first connect, not before you even have a server); **learns about a new version on launch** — a
Home banner + an About notice that open the signed release page (it never auto-downloads or runs an
installer over a possibly-tampered network); system tray + close-to-tray + launch-at-startup;
English / Russian, auto-detected.

All native integration (OLE drag-and-drop, the system proxy, UAC elevation, the WFP fence, QR
screen-scan, the network-change watch, warm-start deep links) lives in the Windows runner with
**no Flutter plugins** — so no Developer Mode is required.

## Build (Windows)

Prerequisites: [Flutter](https://docs.flutter.dev/get-started/install/windows) (stable, Dart ≥ 3.12)
and Visual Studio 2022 with the *Desktop development with C++* workload.

```sh
# 1. fetch the SHA-256-pinned cores into core/windows/ (sing-box + xray + wintun) + rule-sets
#    add -IncludeDesync for the server-less WinDivert DPI-bypass engine (winws + WinDivert)
pwsh tool/fetch-cores.ps1 -IncludeXray -IncludeDesync

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

The installer handles **in-place updates over a running app**: before copying files it stops
`vpn_app.exe` and every core (`sing-box`, `xray`, `winws`, `awg`) so an update can't fail on a
locked file — most importantly `winws.exe`, which keeps the WinDivert kernel driver loaded. The
uninstaller stops the same set so the driver unloads and the files delete cleanly.

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

Done: transport cascade (survivability-ranked) + freeze/whitelist detection, hard-network
(mobile-operator) one-tap mode, anti-DPI fingerprint pool, server-less WinDivert DPI-desync sidecar
(winws), censorship-fact feed, custom routing rules, per-app split-tunnel, Hysteria2 multi-port /
port-hopping, native server-less Telegram unblock (`tgcore` engine) + server-side pin, a **learned
per-network transport memory** (the cascade
remembers which transport survives on your operator and tries it first, across restarts) + a
**DoH-resolver cascade** (resilient name resolution when 1.1.1.1 is blocked) + one-tap **desync-method
escalation**, a **pre-connect whole-profile latency probe**, **Hysteria2/TUIC certificate pinning**
(+ in-app un-pin), an **ECS/ECH advanced UI**, FakeIP DNS, WebDAV profile sync, share-your-setup links + QR,
in-app update notice, ServerGen, in-app diagnostics/speed-test, SHA-256-pinned cores, installer
(with in-place-update process kill) + commit-message release trigger, secret-guarded API, fail-closed
contract. TCP Fast Open and Multipath TCP exist as **advanced opt-in knobs** (off by default; TFO is
flagged risky on RF mobile / AnyTLS).
Remaining: on-hardware kill-switch leak verification (before defaulting it on); share-to-nearby
(AirDrop-like); macOS & Android builds.

## License

**GPL-3.0-or-later** (see [LICENSE](LICENSE)). The app bundles **sing-box** (GPL-3.0) and
**xray-core** (MPL-2.0); the combined distribution is GPL-3.0-or-later. Third-party components and
their licenses are listed in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md); `tool/package.ps1`
ships the full GPL text (`COPYING.txt`) and notices inside every release archive.
