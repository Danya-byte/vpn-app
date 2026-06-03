# Threat model & external-audit scope (vpn-app)

Scope document for a third-party security review (Cure53 / Radically Open
Security / equivalent). It enumerates assets, trust boundaries, attack surface,
the controls already in place, and the highest-value review targets. Pairs with
`SECURITY.md` (policy) and `docs/PREPROD-CHECKLIST.md` (ship gates).

## 1. What this is
A Windows-first anti-censorship VPN client. A Flutter UI drives two bundled cores
— **sing-box** (master) and **xray-core** (an XHTTP bridge) — over a local Clash
API. It generates/imports configs (VLESS+Reality, Hysteria2, TUIC, XHTTP), routes
the OS through them (system-proxy or a TUN adapter), and adds ТСПУ/DPI-survival
features (transport cascade, TLS fragmentation, domestic-relay fronting).

The users are people on adversarial networks (Russian ТСПУ/DPI). For them a defect
is not a crash — it is **deanonymization or interception**. The audit should weigh
findings by that consequence.

## 2. Assets (in priority order)
1. **The user's real IP / the fact they use a VPN** — must not leak to the local
   network or ISP/ТСПУ.
2. **Plaintext traffic** — must never egress outside the tunnel (no DNS/IPv6/proxy
   leaks; fail-closed on core death).
3. **Profile secrets** — node UUIDs, Reality keys, Hysteria/obfs passwords, server
   IPs (stored in `%LOCALAPPDATA%\vpn_app\run\profiles.json`).
4. **Integrity of the running core** — no swapped/poisoned binary, no hostile config
   auto-connecting.
5. **The local control plane** — the Clash API (127.0.0.1:9090) that can read
   connections + switch exit nodes.

## 3. Trust boundaries & data flows
- **OS ↔ app**: the app runs user-level; TUN + the WFP kill-switch need elevation
  (UAC). Native runner code in `windows/runner/` (C++): `kill_switch.cpp` (WFP),
  `flutter_window.cpp` (tray, WM_COPYDATA deeplink), `main.cpp` (single-instance,
  warm-start forwarding), registry handlers.
- **App ↔ cores**: spawned as child processes (`Process.start`) with a per-launch
  Clash API bearer secret; configs written to the runtime dir.
- **App ↔ network**: core dials the chosen server; the app itself fetches
  subscriptions + the update check **through the tunnel**.
- **External → app (UNTRUSTED)**: pasted links, QR images, `vpn://`/`sing-box://`
  deeplinks (cold-launch arg + warm-start WM_COPYDATA), drag-dropped files,
  subscription URLs. **This is the primary attack surface.**

## 4. Attack surface & the controls on it (review these)
| Surface | Risk | Control to verify |
|---|---|---|
| External import (link/QR/deeplink/file/sub) | Hostile config → one-click MITM honeypot / auto-connect | `trusted` flag threads through `importFromFile`/`importDroppedContent`; external paths preview-gate before connect; untrusted sub-URL fetch needs host-named consent BEFORE the network call (`profiles_controller`, `root_scaffold`, `import_actions`) |
| Insecure node (`tls.insecure`, non-Reality/Hy2/TUIC) | Silent MITM exposure | Consent modal on Connect, profiles-list select, **and** the Activity→Policies group switch; auto-failover/cascade exclude insecure leaves (`insecureTagsFromConfig`, `connect_button`, `profiles_sheet`, `activity_page`, `cascade.dart`) |
| Egress leak (DNS / IPv6 / proxy-restore / kill-switch) | Plaintext / real-IP leak | `strict_route` TUN, IPv4+IPv6 capture, hijack-dns, fail-closed `decideExit`, WFP fence (`singbox_config.withTun`, `lifecycle.dart`, `kill_switch.cpp`) |
| WFP kill-switch | Fail-open on install failure; self-strangle; lockout | BLOCK-on-fail (`fenceFailed`), dynamic WFP session (auto-purge), permits sing-box+xray app-ids + tun0 LUID, refuses empty-permit fence (`kill_switch.cpp`, `core_controller`) |
| Clash API (local) | Another local app reads/switches the tunnel | Random per-launch bearer secret (`clash_api.dart`, `singbox_config._clashApi`) |
| Native deeplink (WM_COPYDATA) | Forged payload / buffer overread | OS-marshaled bounds + shape validation + NUL-scan; forwarded deeplinks stay untrusted (`flutter_window.cpp`) |
| Process spawning | PATH/CWD hijack of `taskkill`/`netstat` | Absolute `%SystemRoot%\System32` paths (`core_controller._sys32`) |
| Supply chain | Poisoned core / unsigned release | SHA-256-pinned cores (`fetch-cores.ps1`); tagged release refuses to publish unsigned (`release.yml`, `package.ps1`) |
| Config parsing | Crash / RCE on attacker input | Per-node try-isolation, fuzz tests, no `eval` (`profile_store`, `share_link`, `singbox_config`) |

## 5. Highest-value review targets
1. **The egress perimeter** — can ANY packet reach the open internet outside the
   tunnel across: startup window before the fence, core death, network change,
   sleep/resume, system-proxy mode (no fence), IPv6, DNS. This is the #1 ask.
2. **The WFP fence** (`kill_switch.cpp`) — sublayer arbitration vs a competing VPN,
   LUID race, the no-permit guard, dynamic-session purge correctness.
3. **The import-consent state machine** — any path where external input
   auto-selects/connects, or fetches the network before consent.
4. **The native runner** (C++) — memory safety in WM_COPYDATA / single-instance /
   tray; registry handler scoping (HKCU, opt-in).
5. **Secret handling** — Clash bearer lifetime, profile-store file perms, no secret
   in logs/telemetry (there is no telemetry — verify).

## 6. Out of scope (by design / physics)
- A true protocol-whitelist that drops all but an allow-list can deny service to any
  general tunnel — survivability is best-effort, not guaranteed.
- A compromised chosen server/endpoint (the user's trust in the operator they pick).
- A fully compromised local OS / admin-level malware.
- The bundled cores' own internals (audited upstream; we pin + hash them).

## 7. Known limitations to confirm (not re-discover)
The TUN WFP kill-switch is opt-in/experimental and **not yet leak-tested on
hardware** (`tool/leak-test.ps1` automates the verdict); system-proxy mode has no
fence and can leak DNS; distribution where GitHub is blocked is unsolved for the
*download* (the check runs through the tunnel). Full list in `SECURITY.md` +
`docs/PREPROD-CHECKLIST.md`.

## 8. Build & repro for the auditor
`flutter build windows` with the pinned Flutter (`release.yml` `FLUTTER_VERSION`)
+ SHA-256-pinned cores (`tool/fetch-cores.ps1 -IncludeXray`). 160 unit/widget tests
(`flutter test`) cover the safety contracts (`safety_test`, `h5_*`, `import_*`,
`profile_roundtrip`, `custom_dns`, `hysteria2_brutal`, `first_run_widget`). Builds
are verifiable (pinned), not bit-reproducible (Flutter Windows limitation).
