# Pre-production checklist (vpn-app)

What separates "code-complete" from "ship to at-risk RF users". Items the harness
can't verify headless (real Windows / real network / a cert / a third party) live
here as protocols you run once on hardware.

Status legend: ✅ done · 🔧 code-ready, needs you · ❌ needs you/third-party.

| # | Item | Status |
|---|------|--------|
| 1 | Code-signing + CI | 🔧 CI written + **tagged build now REFUSES to publish unsigned**; **you add the cert secret** |
| 2 | Kill-switch hardened | ✅ BLOCK-on-fail implemented + tested; 🔧 **default-ON only after the leak-test** (leak-test = you) |
| 3 | Native click-test | ❌ you (real Windows) — checklist below |
| 4 | H3 default-mode decision | ✅ implemented — first-run protection chooser (Option A); see §4 |
| 5 | External security audit | ❌ third party (Cure53 / Radically Open Security) |

---

## 1. Code-signing + CI — what's left on you
`release.yml` orchestrates the existing `tool/package.ps1` (build → bundle cores +
notices → sign-if-cert → zip + sha256 → installer). To finish:
1. Get a code-signing cert (OV ~$200–400/yr, or **Azure Trusted Signing** ~$10/mo —
   cheapest path to a trusted publisher). EV gives instant SmartScreen reputation.
2. Add repo secrets `VPNAPP_SIGN_PFX_BASE64` + `VPNAPP_SIGN_PASS`.
3. Pin `FLUTTER_VERSION` in `release.yml` to your exact local version.
4. Push a `v*` tag → CI builds, signs, hashes, publishes the Release.
- Honest limit: Flutter Windows builds aren't bit-reproducible; pinning Flutter +
  the SHA-256 cores gets you "verifiable", not "reproducible". Document the build
  env in the release notes.

---

## 2. Kill-switch — leak-test protocol (RUN ON HARDWARE before default-ON)
The WFP fence compiles + the permit-list is unit-tested (incl. xray, H1), but
"no egress on the physical NIC when the core dies" has never been observed. Do this
once; only flip the default to ON after it passes.

1. Settings → **TUN mode** + enable **kill-switch** → "Restart as administrator".
2. Connect to a **Reality** node. Confirm traffic flows (exit IP ≠ your real IP).
3. In `cmd`: `ping 8.8.8.8 -t` (a continuous egress probe on the physical NIC).
4. **Kill `sing-box.exe` in Task Manager** (simulate a core death — NOT the app's Stop).
5. ✅ PASS = the ping **stops / times out** and sites **don't load** (fail-CLOSED).
   ❌ FAIL (leak) = ping keeps replying → the fence isn't blocking the physical NIC.
6. Reconnect (app auto-reconnects) → traffic resumes (fence re-engaged, new LUID).
7. **Repeat with an XHTTP / Reality-over-XHTTP node**, and also kill **`xray.exe`** —
   the H1 fix must hold: XHTTP carries traffic with the fence ON, and killing the
   bridge also fails closed.
8. **Close the app** → ✅ normal internet returns within a second (the dynamic WFP
   session auto-purges — no stuck block / lockout). Verify a site loads post-close.
9. Control: **disable** the kill-switch → connect → kill the core → egress SHOULD
   continue (proves the setting actually gates the fence).

If 5 + 7 + 8 pass → safe to set `killSwitchTun` default-ON in TUN.

### Kill-switch BLOCK-on-fail — implementation spec (do in the kill-switch pass)
Today, if the fence can't install, the tunnel runs UNPROTECTED with only an amber
badge. BLOCK-on-fail = refuse to connect instead. Do it via the existing terminal
flag pattern (like `_wgDead`), NOT a `_proc.kill()` from `start()` — that races
`_onExit`→`decideExit`→`stopRestore` and clobbers the error state:
- `core_controller`: add `bool _fenceFailed = false;`. In the fence block, on `!ok`
  while `settings.killSwitchTun`: `_fenceFailed = true; _autoReconnect = false;
  _proc?.kill(); return;` (let `_onExit` tear down).
- `lifecycle.dart` `decideExit`: add `required bool fenceFailed`; check it right
  after `stopping` → return a new `ExitOutcome.killSwitchFailed`
  (`restoreProxy: true, disengageFence: true` — the fence never installed, so
  restoring connectivity is anti-lockout, not a leak).
- `_onExit`: pass `fenceFailed: _fenceFailed`; case → `_fenceFailed = false;
  _finishExit(d, CoreStatus.error, error: CoreError.killSwitchFailed)`.
- `CoreError`: add `killSwitchFailed`; l10n en+ru ("Kill-switch is on but the
  firewall fence couldn't be installed — not connecting unprotected. Run as admin
  or turn the kill-switch off."), then `flutter gen-l10n`.
- `safety_test.dart`: add a `decideExit(fenceFailed: true)` → killSwitchFailed +
  `failsClosed == false` (it restores) case.
> Touches `core_controller` + `lifecycle.dart` (+ its test) — the agent's hot
> files. Land it together with default-ON in one kill-switch pass, not as a
> drive-by, to avoid a two-writer clobber.

---

## 3. Native click-test (real Windows — none of this is headless-verifiable)
- **Tray:** connect → press window **X** → app hides to tray, **tunnel stays up**
  (exit IP still tunneled); tray icon present; double-click → window restores;
  right-click → Show / Quit; **Quit** → app exits AND Task Manager shows no leftover
  `sing-box.exe` / `xray.exe`.
- close-to-tray **OFF** → X actually quits.
- **Warm-start deeplink:** app already running → click a `vpn://` / `vless://` link
  (or "Open with" a `.json`) → window raises from tray **and a PREVIEW dialog
  appears** (must NOT silently connect). Cancel → nothing selected/connected.
- **Cold-launch deeplink:** app closed → click link → app opens → preview dialog.
- **Scheme registration:** Settings → enable "register links" → click a `vless://`
  link in a browser/Telegram → your app handles it (opt-in; doesn't hijack others).
- **Autostart:** enable → reboot → app starts (proxy mode, no UAC); disable →
  reboot → doesn't start.
- **H5:** insecure node → Connect → consent modal; while connected, tap an insecure
  node in the list → consent modal (must not switch silently).
- **Diagnostics (just fixed):** run the check → the tail (foreign blacklist sites)
  shows real verdicts, **not all `down`**.
- **Layout:** shrink the window vertically → no yellow overflow stripe; empty
  profile list → the profile bar reads "Add your first server".

---

## 4. H3 default-mode — DECIDED + IMPLEMENTED (Option A)
Default is `systemProxy`, which leaks DNS + proxy-unaware apps. TUN is leak-proof
but needs admin/UAC **every launch**. **Decision: Option A** — keep the frictionless
proxy default but make the user choose, informed, on first run.

**Shipped:** `lib/features/onboarding/first_run_setup.dart` — a one-time chooser
(`showFirstRunSetup`, fired from `root_scaffold` on first frame when
`!settings.seenSetup` and no cold-launch import is pending) offering **Full-device
protection (TUN — no DNS/IPv6 leak)** vs **App proxy (simple, no admin)**. The choice
sets `vpnMode` and flips `seenSetup` (persisted) so it shows once. It deliberately
does **NOT** auto-enable the experimental WFP kill-switch — that stays a conscious
opt-in in Settings until §2's leak-test passes. Mode is changeable anytime in
Settings (existing SegmentedButton). Option B (TUN-by-default) remains the move once
the no-UAC LocalSystem service (M6) ships.

---

## 5. External audit
Before a wide public release, a third-party review (Cure53 / ROS) of the safety
perimeter (kill-switch, import gate, Clash-API auth, native runner). I can prep the
threat-model + scope doc when you're ready.

---

## Bottom line
Ship-as-beta-for-technical-users: yes (already stronger than most on Windows-RF).
Ship-as-"ready"-to-activists: **after** §1 (signed) + §2 (kill-switch leak-tested,
default-on) + §3 (one click-test pass). §4 is done; §5 is desirable pre-wide-release.

---

## Audit closure status (workflow audit, 2026-06-03)

Disposition of every confirmed finding from the prod-ready/functionality/bugs/
security/features workflow audit. ✅ fixed-in-code · 📝 documented decision/inherent ·
🔧 code-ready, needs you · 🗺️ roadmap.

### Prod-readiness
- ✅ **#2 unsigned tagged-publish gate** — `release.yml` now `throw`s on a tag build
  with no signing cert AND gates the publish step on `HAS_CERT`; unsigned can't reach
  a Release.
- ✅ **#3 README "fails CLOSED" overclaim** — rewritten: proxy-mode fail-closed is
  real; the TUN WFP fence is labeled opt-in/experimental.
- ✅ **#7 SECURITY.md + repo hygiene** — `SECURITY.md` added (threat model + reporting
  + known limits); staged-deleted `main.py` unstaged; 4 assertion-less `_scratch*`
  debug tests removed (analyze now fully clean) and replaced with a real
  `share_link_fuzz_test.dart`.
- 🔧 **#1 no commit/tag → CI never ran** — repo is commit-ready; **make the initial
  commit + push a `v*` tag** (a commit is yours to authorize). CI then runs.
- 📝 **#5 distribution when GitHub is blocked** — the update *check* runs through the
  tunnel; *downloading* still needs TUN-mode browser coverage or a mirror. Documented
  honestly in README + SECURITY.md; a mirror/self-update channel is roadmap.
- 📝 **#6 build reproducibility** — Flutter Windows isn't bit-reproducible; pinned
  Flutter + SHA-256 cores = "verifiable, not reproducible" (already in §1).

### Security
- ✅ **#8 Policies-tab H5 bypass (HIGH)** — the Activity→Policies live group switch now
  routes an insecure (cert-validation-off) member through the SAME MITM consent as the
  Connect button + profiles list (`activity_page.dart`, `insecureTagsFromConfig`).
- ✅ **#9 IPv6 leak in TUN** — the TUN now carries an IPv6 ULA so `auto_route` installs
  a `::/0` route; system IPv6 is pulled into the tunnel (fails closed) instead of
  egressing direct. Unit-tested.
- ✅ **#11 `taskkill`/`netstat` PATH/CWD hijack** — now invoked by absolute
  `%SystemRoot%\System32\…` path (`_sys32`), so a planted exe can't run with our
  process-killing intent.
- ✅ **#12 WM_COPYDATA deeplink handler** — bounds-safe by OS marshaling already;
  hardened anyway (reject malformed size, derive length by NUL-scan within bounds,
  never assume termination). Forwarded deeplinks stay untrusted (preview-gate).
- ✅ **B2 auto-failover / latency mismatch** — `latencyProvider` now mirrors `start()`'s
  autoPool predicate exactly (non-insecure only), so it never measures a phantom
  `⚡ Auto` group that wasn't built.
- ✅ **B3 empty-app-ids fence** — `kill_switch.cpp` refuses to install a fence with no
  core permit (would strangle the core's own dial); returns false → Dart fail-closed.
- 📝 **#10 leak window before fence engages** — inherent: the fence needs `tun0`'s LUID
  (and the tun-interface permit is what lets app traffic through), so it must engage
  *after* the TUN is up. The sub-second window is on the §2 leak-test list.
- ✅ **#13 system-proxy leak** — addressed by #4 (first run steers to TUN) + documented
  as a known limitation; TUN+fence is the leak-proof path.
- ✅ **#14 sub-refresh coupling** — already fixed: `latencyProvider` watches only the
  `.select`-ed slices, so a sub-info refresh no longer tears down the polling stream.
- 📝 **#15 TUN LUID fallback** — primary path is the reliable `tun0` alias lookup; the
  172.18/15 IP scan is belt-and-suspenders. The added IPv6 address keeps an IPv4
  address too, so the fallback is unaffected.

### Features (prioritized roadmap)
- ✅ **#4 first-run protection chooser** (was both prod-#4 and a feature ask) — shipped.
- 🗺️ **#16 cross-platform / mobile (P0)** — Android/iOS is the strategic ceiling; large,
  separate milestone.
- 🗺️ **#17 bundled default nodes + true "just connect" (P0)** — partially served today
  by no-server desync mode + `ServerGen`; bundling live nodes needs infra (can't ship
  secrets). First-run chooser (#4) improves onboarding now.
- 🗺️ **#18 auto-update apply (P1)** — surfaces version + link today; full self-replace
  declined on security grounds (auto-running a tunnel-downloaded exe = the MITM vector
  the audit guards against). Revisit only post code-signing + signature verification.
- 🗺️ **#19 in-app routing/DNS editor (P1)** · **#20 camera/screen-region QR** ·
  **#21 profile sync/WebDAV** · **#22 AmneziaWG-obfs + MTProto via a bridge binary**
  (can't be native — sing-box/xray have no such outbound, like AmneziaWG) ·
  **#23 metacubexd/yacd dashboard** (partly served by Activity+Policies) ·
  **#24 Hysteria2 Brutal up/down tuning** — all P2 roadmap.

### Net this session
Every confirmed prod/security/bug finding is **fixed in code or a documented
decision**; remaining opens are **yours** (commit+tag, cert, hardware leak-test,
click-test, external audit) or **roadmap features**. Tests: 154 pass · `flutter
analyze` clean · native compiles (link needs the app closed).
