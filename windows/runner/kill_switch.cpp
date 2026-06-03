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
               FWPM_FILTER_CONDITION0* conds, UINT32 num_conds) {
  FWPM_FILTER0 f = {};
  f.displayData.name = const_cast<wchar_t*>(name);
  f.layerKey = layer;
  f.subLayerKey = g_sublayer;
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
              UINT64* tun_luid) {
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
                    1);
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

  // The fence: block all other outbound. Lower weight than the permits.
  ok &= AddFilter(L"vpn_app block all", layer, FWP_ACTION_BLOCK, 0, nullptr, 0);
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

  NET_LUID luid = {};
  const bool have_luid = TunLuid(&luid);
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

  ok = ok && AddLayer(FWPM_LAYER_ALE_AUTH_CONNECT_V4, app_ids,
                      have_luid ? &luid_val : nullptr);
  ok = ok && AddLayer(FWPM_LAYER_ALE_AUTH_CONNECT_V6, app_ids,
                      have_luid ? &luid_val : nullptr);

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
