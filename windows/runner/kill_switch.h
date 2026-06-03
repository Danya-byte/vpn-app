#ifndef RUNNER_KILL_SWITCH_H_
#define RUNNER_KILL_SWITCH_H_

#include <string>
#include <vector>

// Fail-closed TUN kill-switch via the Windows Filtering Platform (the same
// mechanism WireGuard-for-Windows uses). Engaging installs WFP filters that
// PERMIT only: the core processes (so they can (re)reach the server), the
// tunnel interface "tun0" (so captured app traffic flows), and loopback (the
// local Clash API / mixed proxy); everything else outbound is BLOCKED.
//
// The filters live in a DYNAMIC WFP session, so the OS auto-removes them the
// instant our process exits or crashes — there is NO way to leave the user
// fenced off the network. They must be removed explicitly on a deliberate
// disconnect via [KillSwitchDisengage].
//
// [permit_paths] are the absolute paths to EVERY core binary that makes its own
// outbound to the server — sing-box.exe AND each xray.exe bridge. XHTTP /
// Reality-over-XHTTP ride the xray bridge, which connects out as a SEPARATE
// process, so omitting xray.exe would black those transports out the instant the
// fence goes up (the WFP app-id condition matches by image PATH, so one entry
// covers every xray bridge process). Re-call on each (re)connect (the tunnel
// interface LUID changes per session); it tears down the previous fence first.
// Returns true only if the fence is fully in place — callers must treat false as
// "no protection" (fail-safe: never claim a fence that isn't up).
bool KillSwitchEngage(const std::vector<std::wstring>& permit_paths);

// Remove the fence (close the dynamic session → all filters drop).
void KillSwitchDisengage();

#endif  // RUNNER_KILL_SWITCH_H_
