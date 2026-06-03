# Security policy

This is an anti-censorship VPN client. For its users a security bug can mean a
**deanonymization or interception risk under an adversarial network (ТСПУ/DPI)**,
not just a crash — so we treat the safety perimeter as the priority.

## Reporting a vulnerability

**Do not open a public issue for a security bug.** Email the maintainer at the
address in the repository profile (or use GitHub's *Report a vulnerability*
private advisory). Include: affected version/commit, repro steps, and the impact
you see. We aim to acknowledge within a few days and to ship a fix before any
public disclosure. Coordinated disclosure is appreciated.

Please scrub live secrets (UUIDs, Reality keys, Hysteria/obfs passwords, server
IPs) from anything you send — a redacted repro is enough.

## Supported versions

Pre-1.0: only the latest tagged release (and `main`) receive security fixes.

## Threat model

**In scope**
- Egress leaks: traffic reaching the open internet outside the tunnel
  (DNS/IPv6/proxy-restore races, kill-switch gaps).
- MITM exposure: connecting to a node with certificate validation disabled
  without explicit consent (see the H5 insecure-node gate).
- Hostile imports: a malicious `vless://` / QR / deeplink / subscription causing
  auto-connect or code execution (see the import-consent gate).
- Local control-plane abuse: another local process driving the Clash API.
- Supply chain: a poisoned core binary or unsigned release.

**Out of scope (physics / by design)**
- A true protocol-whitelist that drops everything but a short allow-list can deny
  service to any general-purpose tunnel. We maximize survivability (physics-diverse
  transports, domestic-relay fronting) but cannot *guarantee* reachability.
- A compromised endpoint (your own VPS / the chosen server operator) seeing your
  traffic — that is the trust you place in the server you pick.
- A fully compromised local OS / malware with admin rights.

## Hardening already in place

- **Authenticated control plane** — the Clash API uses a random per-launch
  bearer secret; no unauthenticated local caller can read connections or switch
  exit nodes.
- **Import consent gate** — external imports (drag-drop, cold-launch deeplink/file)
  never auto-connect; they preview the node (protocol/SNI + an insecure badge)
  and connect only on confirmation. An untrusted subscription URL is fetched only
  after a host-named consent.
- **Insecure-node (MITM) consent** — switching the live tunnel onto a
  certificate-validation-off node (Connect button, profiles list, **and** the
  Policies group switcher) requires explicit consent; auto-failover/cascade never
  silently hop onto an insecure node.
- **Pinned, SHA-256-verified cores** — `tool/fetch-cores.ps1` checks each core
  binary's hash before install.
- **Fail-closed proxy handling** — on core death the system proxy stays pointed at
  the dead local port (no silent direct fallback) until a deliberate Stop.
- **No telemetry / no phone-home.** Update checks are opt-in and run through the
  tunnel.

## Known limitations (being worked)

- The **TUN WFP kill-switch fence** is opt-in and experimental; it has not been
  leak-tested on real hardware across adapter/sleep/competing-VPN scenarios.
  Verify before relying on it. See `docs/PREPROD-CHECKLIST.md`.
- **System-proxy mode** has no firewall fence and can leak DNS outside the tunnel;
  prefer TUN mode + the fence for a hostile network.
- **Distribution where GitHub is blocked** is unsolved: the in-app update *check*
  works through the tunnel, but downloading the release still needs the tunnel to
  cover your browser or a mirror.
- Releases are only safe once **code-signed**; an unsigned build trips SmartScreen
  and is itself a supply-chain risk. The release CI refuses to publish a tagged
  build without a signing cert.
