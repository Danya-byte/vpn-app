# Third-party notices

VPN App is GPL-3.0-or-later. It bundles and/or invokes the following third-party
components. Each retains its own license; this file provides the required
attribution. Binaries are fetched (and SHA-256-verified) by `tool/fetch-cores.ps1`
and are **not** committed to this repository.

| Component | Version (pinned) | License | Source |
|-----------|------------------|---------|--------|
| **sing-box** | 1.13.12 | GPL-3.0-or-later | https://github.com/SagerNet/sing-box |
| **xray-core** | 26.3.27 | MPL-2.0 | https://github.com/XTLS/Xray-core |
| **Wintun** | 0.14.1 | Prebuilt driver, see wintun.net license | https://www.wintun.net/ |
| **sing-geoip / sing-geosite rule-sets** (geoip-ru, geosite-category-ru, geosite-category-ads-all) | rule-set branch | CC0 / per-repo | https://github.com/SagerNet/sing-geoip, https://github.com/SagerNet/sing-geosite |
| **Inter** font | bundled (`assets/fonts/Inter.ttf`) | SIL Open Font License 1.1 | https://github.com/rsms/inter |

## Flutter / Dart packages
This app also depends (at build time) on the Flutter SDK and pub packages
declared in `pubspec.yaml` (`flutter_riverpod`, `intl`, `yaml`, `cupertino_icons`,
`flutter_lints`), each under its respective open-source license (BSD-3-Clause /
MIT / Apache-2.0). Run `flutter pub deps` for the full transitive list.

## GPL-3.0 combined-work note
Because sing-box (GPL-3.0) is distributed together with this application, the
combined binary distribution is governed by GPL-3.0-or-later. The corresponding
source for this application is at <https://github.com/Danya-byte/vpn-app>; the
source for the bundled cores is at the URLs above.
