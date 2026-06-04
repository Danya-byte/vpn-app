#include "kill_switch.h"

// winsock2 must precede windows.h (sockaddr_in / ntohl / AF_INET live here, and
// the runner builds with WIN32_LEAN_AND_MEAN which drops winsock from windows.h).
#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>
// fwpmu.h must follow windows.h.
#include <fwpmu.h>
#include <iphlpapi.h>
#include <netioapi.h>
#include <rpc.h>

#pragma comment(lib, "ws2_32.lib")

#pragma comment(lib, "fwpuclnt.lib")
#pragma comment(lib, "iphlpapi.lib")
#pragma comment(lib, "rpcrt4.lib")

namespace {

HANDLE g_engine = nullptr;
GUID g_sublayer = {0};

// Find the sing-box TUN interface LUID. The adapter is named "tun0" (we pin
// that in the generated config); fall back to scanning for the sing-box TUN
// IP range (172.18/172.19.x) used by our configs.
bool TunLuid(NET_LUID* out) {
  if (ConvertInterfaceAliasToLuid(L"tun0", out) == NO_ERROR) return true;

  ULONG size = 0;
  GetAdaptersAddresses(AF_INET, GAA_FLAG_SKIP_DNS_SERVER, nullptr, nullptr,
                       &size);
  if (size == 0) return false;
  auto* buf = reinterpret_cast<IP_ADAPTER_ADDRESSES*>(malloc(size));
  if (!buf) return false;
  bool found = false;
  if (GetAdaptersAddresses(AF_INET, GAA_FLAG_SKIP_DNS_SERVER, nullptr, buf,
                           &size) == NO_ERROR) {
    for (auto* a = buf; a && !found; a = a->Next) {
      for (auto* u = a->FirstUnicastAddress; u; u = u->Next) {
        const auto* sa =
            reinterpret_cast<sockaddr_in*>(u->Address.lpSockaddr);
        if (sa->sin_family != AF_INET) continue;
        const ULONG ip = ntohl(sa->sin_addr.s_addr);
        // 172.18.0.0/15 covers our 172.18.x + 172.19.x TUN ranges.
        if ((ip & 0xFFFE0000u) == 0xAC120000u) {
          out->Value = a->Luid.Value;
          found = true;
          break;
        }
      }
    }
  }
  free(buf);
  return found;
}

bool AddFilter(const wchar_t* name, const GUID& layer,
               FWP_ACTION_TYPE action, UINT8 weight,
               FWPM_FILTER_CONDITION0* conds, UINT32 num_conds,
               bool hard = false) {
  FWPM_FILTER0 f = {};
  f.displayData.name = const_cast<wchar_t*>(name);
  f.layerKey = layer;
  f.subLayerKey = g_sublayer;
  // CLEAR_ACTION_RIGHT makes a verdict AUTHORITATIVE — a competing VPN/AV sublayer
  // can't override it. We set it ONLY on the two security-critical filters: the
  // block-all (so nothing leaks past the fence) and the core app-id permit (so
  // nothing can block the core's dial). NOT on the loopback/tunnel/DHCP/ND
  // conveniences — leaving those soft avoids needlessly overriding a legitimate
  // system policy (the lockout-rigidity WireGuard-Windows also avoids by being
  // selective). Worst case a soft convenience permit loses to a hostile sublayer
  // = a failed reconnect, not a plaintext leak.
  if (hard) f.flags = FWPM_FILTER_FLAG_CLEAR_ACTION_RIGHT;
  f.action.type = action;
  f.weight.type = FWP_UINT8;
  f.weight.uint8 = weight;
  f.numFilterConditions = num_conds;
  f.filterCondition = conds;
  return FwpmFilterAdd0(g_engine, &f, nullptr, nullptr) == ERROR_SUCCESS;
}

// Add the permit (loopback + core processes + tunnel interface) and block
// filters to one layer (V4 or V6).
bool AddLayer(const GUID& layer, const std::vector<FWP_BYTE_BLOB*>& app_ids,
              UINT64* tun_luid, bool is_v6) {
  bool ok = true;

  FWPM_FILTER_CONDITION0 loopback = {};
  loopback.fieldKey = FWPM_CONDITION_FLAGS;
  loopback.matchType = FWP_MATCH_FLAGS_ALL_SET;
  loopback.conditionValue.type = FWP_UINT32;
  loopback.conditionValue.uint32 = FWP_CONDITION_FLAG_IS_LOOPBACK;
  ok &= AddFilter(L"vpn_app permit loopback", layer, FWP_ACTION_PERMIT, 13,
                  &loopback, 1);

  // One permit per core binary (sing-box + each xray bridge) so every core can
  // reach its server while the fence blocks everything else.
  for (FWP_BYTE_BLOB* app_id : app_ids) {
    if (!app_id) continue;
    FWPM_FILTER_CONDITION0 core = {};
    core.fieldKey = FWPM_CONDITION_ALE_APP_ID;
    core.matchType = FWP_MATCH_EQUAL;
    core.conditionValue.type = FWP_BYTE_BLOB_TYPE;
    core.conditionValue.byteBlob = app_id;
    ok &= AddFilter(L"vpn_app permit core", layer, FWP_ACTION_PERMIT, 13, &core,
                    1, /*hard=*/true);
  }

  if (tun_luid) {
    FWPM_FILTER_CONDITION0 iface = {};
    iface.fieldKey = FWPM_CONDITION_IP_LOCAL_INTERFACE;
    iface.matchType = FWP_MATCH_EQUAL;
    iface.conditionValue.type = FWP_UINT64;
    iface.conditionValue.uint64 = tun_luid;
    ok &= AddFilter(L"vpn_app permit tunnel", layer, FWP_ACTION_PERMIT, 13,
                    &iface, 1);
  }

  // Permit the OS infrastructure traffic that must keep flowing while the fence
  // is up, or the machine self-inflicts a network lockout during the very moment
  // it's fighting censorship: DHCPv4 lease renewal (v4) and IPv6 Neighbor
  // Discovery (v6). WireGuard-Windows permits these for the same reason. Weight
  // 12 → above the block (0), below our app/loopback/tunnel permits (13).
  if (!is_v6) {
    FWPM_FILTER_CONDITION0 dhcp[2] = {};
    dhcp[0].fieldKey = FWPM_CONDITION_IP_PROTOCOL;
    dhcp[0].matchType = FWP_MATCH_EQUAL;
    dhcp[0].conditionValue.type = FWP_UINT8;
    dhcp[0].conditionValue.uint8 = 17;  // IPPROTO_UDP
    dhcp[1].fieldKey = FWPM_CONDITION_IP_REMOTE_PORT;
    dhcp[1].matchType = FWP_MATCH_EQUAL;
    dhcp[1].conditionValue.type = FWP_UINT16;
    dhcp[1].conditionValue.uint16 = 67;  // DHCP server port
    ok &=
        AddFilter(L"vpn_app permit dhcp", layer, FWP_ACTION_PERMIT, 12, dhcp, 2);
  } else {
    // IPv6 Neighbor Discovery ONLY (ICMPv6 types 133-136: Router Solicit/Advert +
    // Neighbor Solicit/Advert) so v6 doesn't self-lockout. NOT blanket proto-58 —
    // that would also permit ICMPv6 Echo (ping -6) to leak out the physical NIC
    // when the tunnel is down (an active-probe signal to the DPI).
    for (UINT16 t = 133; t <= 136; ++t) {
      FWPM_FILTER_CONDITION0 nd[2] = {};
      nd[0].fieldKey = FWPM_CONDITION_IP_PROTOCOL;
      nd[0].matchType = FWP_MATCH_EQUAL;
      nd[0].conditionValue.type = FWP_UINT8;
      nd[0].conditionValue.uint8 = 58;  // IPPROTO_ICMPV6
      nd[1].fieldKey = FWPM_CONDITION_ICMP_TYPE;
      nd[1].matchType = FWP_MATCH_EQUAL;
      nd[1].conditionValue.type = FWP_UINT16;
      nd[1].conditionValue.uint16 = t;
      ok &= AddFilter(L"vpn_app permit icmpv6 nd", layer, FWP_ACTION_PERMIT, 12,
                      nd, 2);
    }
    // DHCPv6 lease renewal (client sends from 546 -> server 547).
    FWPM_FILTER_CONDITION0 dhcp6[2] = {};
    dhcp6[0].fieldKey = FWPM_CONDITION_IP_PROTOCOL;
    dhcp6[0].matchType = FWP_MATCH_EQUAL;
    dhcp6[0].conditionValue.type = FWP_UINT8;
    dhcp6[0].conditionValue.uint8 = 17;  // IPPROTO_UDP
    dhcp6[1].fieldKey = FWPM_CONDITION_IP_REMOTE_PORT;
    dhcp6[1].matchType = FWP_MATCH_EQUAL;
    dhcp6[1].conditionValue.type = FWP_UINT16;
    dhcp6[1].conditionValue.uint16 = 547;  // DHCPv6 server port
    ok &= AddFilter(L"vpn_app permit dhcpv6", layer, FWP_ACTION_PERMIT, 12, dhcp6,
                    2);
  }

  // The fence: block all other outbound. Lower weight than the permits, and HARD
  // (CLEAR_ACTION_RIGHT) so a competing VPN/AV sublayer can't leak past it.
  ok &= AddFilter(L"vpn_app block all", layer, FWP_ACTION_BLOCK, 0, nullptr, 0,
                  /*hard=*/true);
  return ok;
}

}  // namespace

bool KillSwitchEngage(const std::vector<std::wstring>& permit_paths) {
  // Tear down any previous fence (interface LUID changes per session).
  KillSwitchDisengage();

  FWPM_SESSION0 session = {};
  session.flags = FWPM_SESSION_FLAG_DYNAMIC;  // auto-purge on process exit
  if (FwpmEngineOpen0(nullptr, RPC_C_AUTHN_WINNT, nullptr, &session,
                      &g_engine) != ERROR_SUCCESS) {
    g_engine = nullptr;
    return false;
  }

  // One app-id per core binary (sing-box + each xray bridge). Best-effort: a
  // path that doesn't resolve is skipped, not fatal (the others still permit).
  std::vector<FWP_BYTE_BLOB*> app_ids;
  for (const std::wstring& path : permit_paths) {
    if (path.empty()) continue;
    FWP_BYTE_BLOB* blob = nullptr;
    if (FwpmGetAppIdFromFileName0(path.c_str(), &blob) == ERROR_SUCCESS && blob) {
      app_ids.push_back(blob);
    }
  }
  auto free_app_ids = [&]() {
    for (FWP_BYTE_BLOB* b : app_ids) {
      FwpmFreeMemory0(reinterpret_cast<void**>(&b));
    }
    app_ids.clear();
  };

  // No core binary resolved → a fence here would permit loopback/tunnel but
  // BLOCK the core's own dial to the server (it leaves via the physical NIC, not
  // tun0), strangling the tunnel it's meant to protect. Refuse to install a
  // self-defeating fence; the Dart layer treats false as fail-closed (refuse to
  // run unprotected) rather than silently killing connectivity.
  if (app_ids.empty()) {
    KillSwitchDisengage();  // close the engine we just opened
    return false;
  }

  // Resolve the tunnel interface LUID. ONE attempt — no Sleep here: this runs on
  // the platform/message-pump thread, so blocking would freeze the UI. tun0 can
  // lag the core's start, so the DART side retries fenceEngage with a delay
  // between attempts (off the UI thread via `await`).
  NET_LUID luid = {};
  if (!TunLuid(&luid)) {
    // No tunnel interface yet. A fence with no tun0 permit would BLOCK the user's
    // OWN captured traffic (it egresses via tun0, which nothing permits) while the
    // core still dials out fine — a silent self-DoS. Refuse; Dart treats false as
    // fail-closed (retry, then don't run unprotected).
    free_app_ids();
    KillSwitchDisengage();
    return false;
  }
  UINT64 luid_val = luid.Value;

  if (UuidCreate(&g_sublayer) != RPC_S_OK) {
    free_app_ids();
    KillSwitchDisengage();
    return false;
  }

  bool ok = FwpmTransactionBegin0(g_engine, 0) == ERROR_SUCCESS;

  FWPM_SUBLAYER0 sub = {};
  sub.subLayerKey = g_sublayer;
  sub.displayData.name = const_cast<wchar_t*>(L"vpn_app killswitch");
  sub.weight = 0xFFFF;
  ok = ok && FwpmSubLayerAdd0(g_engine, &sub, nullptr) == ERROR_SUCCESS;

  ok = ok && AddLayer(FWPM_LAYER_ALE_AUTH_CONNECT_V4, app_ids, &luid_val, false);
  ok = ok && AddLayer(FWPM_LAYER_ALE_AUTH_CONNECT_V6, app_ids, &luid_val, true);

  if (ok) {
    ok = FwpmTransactionCommit0(g_engine) == ERROR_SUCCESS;
  } else {
    FwpmTransactionAbort0(g_engine);
  }

  free_app_ids();

  if (!ok) {
    KillSwitchDisengage();  // fail-safe: never claim a half-built fence
    return false;
  }
  return true;
}

void KillSwitchDisengage() {
  if (g_engine) {
    // Closing the dynamic engine drops the sublayer + every filter with it.
    FwpmEngineClose0(g_engine);
    g_engine = nullptr;
  }
  g_sublayer = GUID{0};
}
