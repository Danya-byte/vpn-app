#include "flutter_window.h"

#include "kill_switch.h"

#include <commdlg.h>
#include <flutter/standard_method_codec.h>
#include <iphlpapi.h>
#include <ole2.h>
#include <oleidl.h>
#include <shellapi.h>
#include <wininet.h>

#include <cstdint>
#include <optional>
#include <string>
#include <variant>
#include <vector>

#include "flutter/generated_plugin_registrant.h"
#include "resource.h"
#include "utils.h"

#pragma comment(lib, "comdlg32.lib")
#pragma comment(lib, "iphlpapi.lib")
#pragma comment(lib, "ole32.lib")
#pragma comment(lib, "shell32.lib")
#pragma comment(lib, "wininet.lib")

// Posted from the network-watch thread when the network changes.
constexpr UINT kNetworkChangedMsg = WM_APP + 100;
constexpr UINT kTrayMsg = WM_APP + 101;  // tray-icon mouse callbacks
constexpr UINT kTrayUid = 1;
constexpr UINT kTrayShowCmd = 0xA001;  // WM_COMMAND ids for the tray menu
constexpr UINT kTrayQuitCmd = 0xA002;

namespace {

// OLE drop target on the Flutter view: forwards drag-enter/leave + the dropped
// file path to the FlutterWindow so the UI can show an overlay and import.
class FileDropTarget : public IDropTarget {
 public:
  explicit FileDropTarget(FlutterWindow* owner) : owner_(owner) {}

  HRESULT STDMETHODCALLTYPE QueryInterface(REFIID riid, void** ppv) override {
    if (riid == IID_IUnknown || riid == IID_IDropTarget) {
      *ppv = static_cast<IDropTarget*>(this);
      AddRef();
      return S_OK;
    }
    *ppv = nullptr;
    return E_NOINTERFACE;
  }
  ULONG STDMETHODCALLTYPE AddRef() override { return ++ref_; }
  ULONG STDMETHODCALLTYPE Release() override {
    const ULONG r = --ref_;
    if (r == 0) delete this;
    return r;
  }

  HRESULT STDMETHODCALLTYPE DragEnter(IDataObject* data, DWORD, POINTL,
                                      DWORD* effect) override {
    has_files_ = HasFiles(data);
    *effect = has_files_ ? DROPEFFECT_COPY : DROPEFFECT_NONE;
    if (has_files_ && owner_) owner_->OnDragEnter();
    return S_OK;
  }
  HRESULT STDMETHODCALLTYPE DragOver(DWORD, POINTL, DWORD* effect) override {
    *effect = has_files_ ? DROPEFFECT_COPY : DROPEFFECT_NONE;
    return S_OK;
  }
  HRESULT STDMETHODCALLTYPE DragLeave() override {
    if (owner_) owner_->OnDragLeave();
    return S_OK;
  }
  HRESULT STDMETHODCALLTYPE Drop(IDataObject* data, DWORD, POINTL,
                                 DWORD* effect) override {
    *effect = DROPEFFECT_COPY;
    if (owner_) owner_->OnDragLeave();
    if (!owner_) return S_OK;
    // 1) Real files on disk -> import by path.
    {
      FORMATETC f = {CF_HDROP, nullptr, DVASPECT_CONTENT, -1, TYMED_HGLOBAL};
      STGMEDIUM stg;
      if (SUCCEEDED(data->GetData(&f, &stg))) {
        bool ok = false;
        auto drop = static_cast<HDROP>(GlobalLock(stg.hGlobal));
        if (drop) {
          // Import EVERY dropped file, not just the first — a multi-file drop was
          // silently losing the rest.
          const UINT count = DragQueryFileW(drop, 0xFFFFFFFF, nullptr, 0);
          wchar_t path[MAX_PATH];
          for (UINT i = 0; i < count; i++) {
            if (DragQueryFileW(drop, i, path, MAX_PATH) > 0) {
              owner_->OnFileDropped(Utf8FromUtf16(path));
              ok = true;
            }
          }
          GlobalUnlock(stg.hGlobal);
        }
        ReleaseStgMedium(&stg);
        if (ok) return S_OK;
      }
    }
    // 2) Virtual file contents (e.g. dragged from a Telegram/browser bubble).
    {
      FORMATETC f = {(CLIPFORMAT)FileContentsFormat(), nullptr,
                     DVASPECT_CONTENT, 0, TYMED_ISTREAM | TYMED_HGLOBAL};
      STGMEDIUM stg;
      if (SUCCEEDED(data->GetData(&f, &stg))) {
        auto bytes = ReadMedium(stg);
        ReleaseStgMedium(&stg);
        if (!bytes.empty()) {
          owner_->OnContentDropped(bytes);
          return S_OK;
        }
      }
    }
    // 3) Plain dragged text / a share link.
    {
      FORMATETC f = {CF_UNICODETEXT, nullptr, DVASPECT_CONTENT, -1,
                     TYMED_HGLOBAL};
      STGMEDIUM stg;
      if (SUCCEEDED(data->GetData(&f, &stg))) {
        const SIZE_T cap = GlobalSize(stg.hGlobal) / sizeof(wchar_t);
        auto p = static_cast<const wchar_t*>(GlobalLock(stg.hGlobal));
        if (p) {
          size_t n = 0;
          while (n < cap && p[n] != L'\0') ++n;  // bounded; don't trust the NUL
          const std::wstring w(p, n);
          GlobalUnlock(stg.hGlobal);
          const std::string utf8 = Utf8FromUtf16(w.c_str());
          owner_->OnContentDropped(
              std::vector<uint8_t>(utf8.begin(), utf8.end()));
        }
        ReleaseStgMedium(&stg);
        return S_OK;
      }
    }
    return S_OK;
  }

 private:
  static UINT FileContentsFormat() {
    static const UINT cf = RegisterClipboardFormatW(L"FileContents");
    return cf;
  }
  static bool Has(IDataObject* data, UINT cf, DWORD tymed, LONG lindex) {
    FORMATETC f = {(CLIPFORMAT)cf, nullptr, DVASPECT_CONTENT, lindex, tymed};
    return data && data->QueryGetData(&f) == S_OK;
  }
  static bool HasFiles(IDataObject* data) {
    return Has(data, CF_HDROP, TYMED_HGLOBAL, -1) ||
           Has(data, CF_UNICODETEXT, TYMED_HGLOBAL, -1) ||
           Has(data, FileContentsFormat(), TYMED_ISTREAM | TYMED_HGLOBAL, 0);
  }
  static std::vector<uint8_t> ReadMedium(const STGMEDIUM& stg) {
    std::vector<uint8_t> out;
    if (stg.tymed == TYMED_ISTREAM && stg.pstm) {
      ULONG read = 0;
      uint8_t buf[65536];
      for (;;) {
        const HRESULT hr = stg.pstm->Read(buf, sizeof(buf), &read);
        if (read > 0) {
          out.insert(out.end(), buf, buf + read);
          if (out.size() > 4u * 1024 * 1024) break;
        }
        // Many IStream impls return S_FALSE on the last chunk that still has
        // bytes, so append first, then stop on anything that isn't S_OK / EOF.
        if (hr != S_OK || read == 0) break;
      }
    } else if (stg.tymed == TYMED_HGLOBAL && stg.hGlobal) {
      const SIZE_T n = GlobalSize(stg.hGlobal);
      auto p = static_cast<const uint8_t*>(GlobalLock(stg.hGlobal));
      if (p) {
        out.assign(p, p + n);
        GlobalUnlock(stg.hGlobal);
      }
    }
    return out;
  }

  FlutterWindow* owner_;
  ULONG ref_ = 1;
  bool has_files_ = false;
};

// Windows system-proxy control with backup/restore, so we never clobber the
// user's existing proxy: SetSystemProxy backs up the current settings once,
// RestoreSystemProxy puts them back (also recovers after a crash).
const wchar_t kInetKey[] =
    L"Software\\Microsoft\\Windows\\CurrentVersion\\Internet Settings";
const wchar_t kBackupKey[] = L"Software\\vpn_app";

// Proper UTF-8 -> UTF-16. The old `std::wstring(s.begin(), s.end())` just
// sign-extends each byte, corrupting any non-ASCII value written to the
// registry (a garbage ProxyServer = the user loses all internet).
std::wstring Utf16FromUtf8(const std::string& s) {
  if (s.empty()) return std::wstring();
  const int n = MultiByteToWideChar(CP_UTF8, 0, s.data(),
                                    static_cast<int>(s.size()), nullptr, 0);
  std::wstring w(n, L'\0');
  MultiByteToWideChar(CP_UTF8, 0, s.data(), static_cast<int>(s.size()), &w[0],
                      n);
  return w;
}

// True ONLY if a proxy value points at OUR OWN mixed-inbound endpoint
// (127.0.0.1:2080 — must match SingBoxConfig.mixedListen:mixedPort). NOT any
// loopback: a user's deliberate local proxy (cntlm / Px / Fiddler / Burp on a
// DIFFERENT loopback port) and a real upstream in the per-protocol
// "http=127.0.0.1:8080;https=realproxy:8080" form both legitimately mention
// 127.0.0.1 — they MUST be backed up + restored, never mistaken for ours and
// dropped. The :2080 port is the anchor that tells our own dead pointer (safe to
// clear) apart from the user's live proxy (must be kept). Substring (find)
// tolerates a scheme prefix ("http://127.0.0.1:2080"); the specific port makes a
// collision with a real proxy vanishingly unlikely.
bool IsOwnLoopback(const std::wstring& proxy) {
  return proxy.find(L"127.0.0.1:2080") != std::wstring::npos ||
         proxy.find(L"localhost:2080") != std::wstring::npos ||
         proxy.find(L"[::1]:2080") != std::wstring::npos;
}

void NotifyProxyChanged() {
  InternetSetOptionW(nullptr, INTERNET_OPTION_SETTINGS_CHANGED, nullptr, 0);
  InternetSetOptionW(nullptr, INTERNET_OPTION_REFRESH, nullptr, 0);
}

DWORD ReadDword(const wchar_t* sub, const wchar_t* name, DWORD def) {
  DWORD val = def, size = sizeof(val);
  HKEY k;
  if (RegOpenKeyExW(HKEY_CURRENT_USER, sub, 0, KEY_READ, &k) == ERROR_SUCCESS) {
    RegQueryValueExW(k, name, nullptr, nullptr, reinterpret_cast<BYTE*>(&val),
                     &size);
    RegCloseKey(k);
  }
  return val;
}

std::wstring ReadString(const wchar_t* sub, const wchar_t* name) {
  HKEY k;
  std::wstring out;
  if (RegOpenKeyExW(HKEY_CURRENT_USER, sub, 0, KEY_READ, &k) == ERROR_SUCCESS) {
    // Size first, then read into a RIGHT-SIZED buffer. A fixed 1024-wchar buffer
    // returned ERROR_MORE_DATA (not SUCCESS) on a long ProxyServer (a multi-
    // protocol list), leaving the value empty → an empty backup → a later
    // restore WIPED the user's real proxy. So never truncate.
    DWORD size = 0, type = 0;
    if (RegQueryValueExW(k, name, nullptr, &type, nullptr, &size) ==
            ERROR_SUCCESS &&
        type == REG_SZ && size >= sizeof(wchar_t)) {
      std::wstring buf(size / sizeof(wchar_t), L'\0');
      if (RegQueryValueExW(k, name, nullptr, &type,
                           reinterpret_cast<BYTE*>(&buf[0]),
                           &size) == ERROR_SUCCESS) {
        out.assign(buf.c_str());  // c_str() trims at the terminating NUL
      }
    }
    RegCloseKey(k);
  }
  return out;
}

void WriteDword(const wchar_t* sub, const wchar_t* name, DWORD val) {
  HKEY k;
  if (RegCreateKeyExW(HKEY_CURRENT_USER, sub, 0, nullptr, 0, KEY_WRITE, nullptr,
                      &k, nullptr) == ERROR_SUCCESS) {
    RegSetValueExW(k, name, 0, REG_DWORD, reinterpret_cast<const BYTE*>(&val),
                   sizeof(val));
    RegCloseKey(k);
  }
}

void WriteString(const wchar_t* sub, const wchar_t* name,
                 const std::wstring& val) {
  HKEY k;
  if (RegCreateKeyExW(HKEY_CURRENT_USER, sub, 0, nullptr, 0, KEY_WRITE, nullptr,
                      &k, nullptr) == ERROR_SUCCESS) {
    RegSetValueExW(k, name, 0, REG_SZ,
                   reinterpret_cast<const BYTE*>(val.c_str()),
                   static_cast<DWORD>((val.size() + 1) * sizeof(wchar_t)));
    RegCloseKey(k);
  }
}

// ── OS integration (all HKCU, so NO admin) ──────────────────────────────────

// Register vpn:// + sing-box:// URL handlers and add us to the .json "Open with"
// list (NOT as the default handler — never hijack all .json). Opt-in from
// Settings, because Windows is "last-installed wins" for schemes.
void RegisterLinkHandlers() {
  wchar_t exe[MAX_PATH] = {};
  GetModuleFileNameW(nullptr, exe, MAX_PATH);
  const std::wstring cmd = L"\"" + std::wstring(exe) + L"\" \"%1\"";
  for (const wchar_t* scheme : {L"vpn", L"sing-box"}) {
    const std::wstring base = std::wstring(L"Software\\Classes\\") + scheme;
    WriteString(base.c_str(), L"", std::wstring(L"URL:") + scheme);
    WriteString(base.c_str(), L"URL Protocol", L"");
    WriteString((base + L"\\shell\\open\\command").c_str(), L"", cmd);
  }
  WriteString(
      L"Software\\Classes\\Applications\\vpn_app.exe\\shell\\open\\command",
      L"", cmd);
  WriteString(L"Software\\Classes\\Applications\\vpn_app.exe\\SupportedTypes",
              L".json", L"");
}

void UnregisterLinkHandlers() {
  RegDeleteTreeW(HKEY_CURRENT_USER, L"Software\\Classes\\vpn");
  RegDeleteTreeW(HKEY_CURRENT_USER, L"Software\\Classes\\sing-box");
  RegDeleteTreeW(HKEY_CURRENT_USER,
                 L"Software\\Classes\\Applications\\vpn_app.exe");
}

const wchar_t* kRunKey =
    L"Software\\Microsoft\\Windows\\CurrentVersion\\Run";

// Launch-at-login via HKCU\...\Run (no admin). [minimized] adds --minimized so
// an autostarted copy comes up in the tray, not in the user's face every boot.
void SetAutostart(bool on, bool minimized) {
  if (on) {
    wchar_t exe[MAX_PATH] = {};
    GetModuleFileNameW(nullptr, exe, MAX_PATH);
    std::wstring cmd = L"\"" + std::wstring(exe) + L"\"";
    if (minimized) cmd += L" --minimized";
    WriteString(kRunKey, L"vpn_app", cmd);
  } else {
    HKEY k;
    if (RegOpenKeyExW(HKEY_CURRENT_USER, kRunKey, 0, KEY_WRITE, &k) ==
        ERROR_SUCCESS) {
      RegDeleteValueW(k, L"vpn_app");
      RegCloseKey(k);
    }
  }
}

bool IsAutostartEnabled() { return !ReadString(kRunKey, L"vpn_app").empty(); }

bool SetSystemProxy(const std::wstring& server) {
  // Snapshot the user's proxy once — but never back up OUR OWN value (a stale
  // 127.0.0.1:2080 left by an unclean exit), or a later restore would point them
  // back at our own dead port. A proxy the USER set — including a local one on a
  // different port — IS backed up, so disconnect restores it faithfully.
  const std::wstring current = ReadString(kInetKey, L"ProxyServer");
  if (ReadDword(kBackupKey, L"BackupValid", 0) == 0 && current != server &&
      !IsOwnLoopback(current)) {
    WriteDword(kBackupKey, L"BackupEnable",
               ReadDword(kInetKey, L"ProxyEnable", 0));
    WriteString(kBackupKey, L"BackupServer", current);
    WriteString(kBackupKey, L"BackupOverride",
                ReadString(kInetKey, L"ProxyOverride"));
    WriteDword(kBackupKey, L"BackupValid", 1);
  }
  WriteDword(kInetKey, L"ProxyEnable", 1);
  WriteString(kInetKey, L"ProxyServer", server);
  WriteString(kInetKey, L"ProxyOverride", L"<local>");
  NotifyProxyChanged();
  // Verify the write actually landed — a denied/failed registry write must NOT
  // look like success, or proxy mode fails OPEN silently (apps go direct).
  return ReadString(kInetKey, L"ProxyServer") == server &&
         ReadDword(kInetKey, L"ProxyEnable", 0) == 1;
}

void RestoreSystemProxy() {
  if (ReadDword(kBackupKey, L"BackupValid", 0) == 1) {
    WriteDword(kInetKey, L"ProxyEnable",
               ReadDword(kBackupKey, L"BackupEnable", 0));
    WriteString(kInetKey, L"ProxyServer", ReadString(kBackupKey, L"BackupServer"));
    WriteString(kInetKey, L"ProxyOverride",
                ReadString(kBackupKey, L"BackupOverride"));
    WriteDword(kBackupKey, L"BackupValid", 0);
    NotifyProxyChanged();
    return;
  }
  // No real backup to restore. If the system proxy still points at OUR OWN dead
  // 127.0.0.1:2080 (we set it on connect; nothing serves it now), DISABLE it so the
  // browser falls back to DIRECT instead of erroring on a non-serving port
  // (ERR_PROXY_CONNECTION_FAILED). The user's own proxy — a real upstream, or a
  // local one on another port — is never ours, so it is left untouched.
  if (ReadDword(kInetKey, L"ProxyEnable", 0) == 1 &&
      IsOwnLoopback(ReadString(kInetKey, L"ProxyServer"))) {
    WriteDword(kInetKey, L"ProxyEnable", 0);
    NotifyProxyChanged();
  }
}

// Grab the whole virtual screen into an in-memory 32bpp BMP (no encoder / extra
// lib — just a header + the DIB bits). Fed straight to the existing QR decoder so
// a config QR shown on screen (e.g. in Telegram Desktop) can be scanned without a
// camera. Empty vector on failure.
std::vector<uint8_t> CaptureScreenBmp() {
  const int x = GetSystemMetrics(SM_XVIRTUALSCREEN);
  const int y = GetSystemMetrics(SM_YVIRTUALSCREEN);
  const int w = GetSystemMetrics(SM_CXVIRTUALSCREEN);
  const int h = GetSystemMetrics(SM_CYVIRTUALSCREEN);
  std::vector<uint8_t> out;
  if (w <= 0 || h <= 0) return out;
  HDC screen = GetDC(nullptr);
  if (!screen) return out;
  HDC mem = CreateCompatibleDC(screen);
  HBITMAP bmp = CreateCompatibleBitmap(screen, w, h);
  if (mem && bmp) {
    HGDIOBJ old = SelectObject(mem, bmp);
    BitBlt(mem, 0, 0, w, h, screen, x, y, SRCCOPY);
    BITMAPINFOHEADER bi = {};
    bi.biSize = sizeof(BITMAPINFOHEADER);
    bi.biWidth = w;
    bi.biHeight = -h;  // top-down
    bi.biPlanes = 1;
    bi.biBitCount = 32;
    bi.biCompression = BI_RGB;
    const size_t pix = static_cast<size_t>(w) * static_cast<size_t>(h) * 4;
    out.resize(54 + pix);  // 14-byte file header + 40-byte info header + bits
    out[0] = 'B';
    out[1] = 'M';
    const uint32_t fsize = static_cast<uint32_t>(out.size());
    memcpy(&out[2], &fsize, 4);
    const uint32_t off = 54;
    memcpy(&out[10], &off, 4);
    memcpy(&out[14], &bi, sizeof(bi));
    BITMAPINFO info = {};
    info.bmiHeader = bi;
    if (GetDIBits(mem, bmp, 0, h, &out[54], &info, DIB_RGB_COLORS) == 0) {
      out.clear();
    }
    SelectObject(mem, old);
  }
  if (bmp) DeleteObject(bmp);
  if (mem) DeleteDC(mem);
  ReleaseDC(nullptr, screen);
  return out;
}

bool IsElevated() {
  bool elevated = false;
  HANDLE token = nullptr;
  if (OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &token)) {
    TOKEN_ELEVATION te;
    DWORD size = sizeof(te);
    if (GetTokenInformation(token, TokenElevation, &te, sizeof(te), &size)) {
      elevated = te.TokenIsElevated != 0;
    }
    CloseHandle(token);
  }
  return elevated;
}

// Legacy shell file-drop fallback for the ELEVATED case. OLE drag-drop
// (IDropTarget) can't cross the UIPI integrity boundary into an admin window —
// the cross-process COM negotiation is blocked, so the cursor shows a red ✕ and
// no events arrive, and message filters don't fix it. The legacy DragAcceptFiles
// + WM_DROPFILES path DOES cross UIPI (with the WM_DROPFILES/WM_COPYGLOBALDATA
// message filter set in OnCreate), so when elevated we subclass the Flutter view
// to catch WM_DROPFILES over the client area and forward each path to Dart. No
// hover overlay (the legacy path has no drag-enter event) — but a config file
// can still be dropped, which is the whole point.
static WNDPROC g_orig_view_proc = nullptr;
static FlutterWindow* g_drop_owner = nullptr;

LRESULT CALLBACK ElevatedDropProc(HWND hwnd, UINT msg, WPARAM wparam,
                                  LPARAM lparam) {
  if (msg == WM_DROPFILES) {
    auto drop = reinterpret_cast<HDROP>(wparam);
    const UINT count = DragQueryFileW(drop, 0xFFFFFFFF, nullptr, 0);
    for (UINT i = 0; i < count; i++) {
      wchar_t path[MAX_PATH];
      if (DragQueryFileW(drop, i, path, MAX_PATH) > 0 && g_drop_owner) {
        g_drop_owner->OnFileDropped(Utf8FromUtf16(path));
      }
    }
    DragFinish(drop);
    return 0;
  }
  return ::CallWindowProc(g_orig_view_proc, hwnd, msg, wparam, lparam);
}

void RelaunchElevated() {
  wchar_t path[MAX_PATH];
  if (GetModuleFileNameW(nullptr, path, MAX_PATH) == 0) return;
  // Working directory = the exe's own folder. A "runas" elevation otherwise gives
  // the new process CWD=system32, and in a dev/DEBUG layout (cores live in the
  // project's core/, NOT beside build\...\Debug\vpn_app.exe) CorePaths' CWD
  // walk-up then can't reach them → coreMissing → the elevated copy silently fails
  // to start the tunnel. Pinning CWD to the exe dir lets the walk-up find the dev
  // core/ AND keeps a release exe's adjacent core/ resolvable.
  wchar_t dir[MAX_PATH];
  wcsncpy_s(dir, MAX_PATH, path, _TRUNCATE);
  if (wchar_t* slash = wcsrchr(dir, L'\\')) *slash = L'\0';
  SHELLEXECUTEINFOW sei = {sizeof(sei)};
  sei.lpVerb = L"runas";
  sei.lpFile = path;
  sei.lpDirectory = dir;
  // Tell the elevated copy this is a deliberate relaunch so it bypasses the
  // single-instance guard (otherwise it sees THIS still-alive instance and
  // exits → "restart as admin does nothing").
  sei.lpParameters = L"--elevated-relaunch";
  sei.nShow = SW_SHOWNORMAL;
  if (ShellExecuteExW(&sei)) {
    PostQuitMessage(0);  // elevated instance launched; exit this one
  }
}

// Kill any sing-box/xray WE spawned, from the PID ledger Dart writes
// (%LOCALAPPDATA%\vpn_app\run\core.pids, one "image\tpid" line each). The image
// name is verified against the live process (guards a reused PID), so an
// unrelated process is never touched. Runs on teardown so closing the window
// never leaves a headless core tunnelling the whole machine (TUN) or holding the
// local ports on the next launch — the "closed the app, lost all internet" class.
void KillCoreOrphans() {
  wchar_t base[MAX_PATH];
  DWORD n = GetEnvironmentVariableW(L"LOCALAPPDATA", base, MAX_PATH);
  if (n == 0 || n >= MAX_PATH) return;
  std::wstring path = std::wstring(base) + L"\\vpn_app\\run\\core.pids";
  HANDLE f =
      CreateFileW(path.c_str(), GENERIC_READ,
                  FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr, OPEN_EXISTING,
                  FILE_ATTRIBUTE_NORMAL, nullptr);
  if (f == INVALID_HANDLE_VALUE) return;
  std::string content;
  char buf[1024];
  DWORD got = 0;
  while (ReadFile(f, buf, sizeof(buf), &got, nullptr) && got > 0) {
    content.append(buf, got);
  }
  CloseHandle(f);

  size_t pos = 0;
  while (pos < content.size()) {
    size_t eol = content.find('\n', pos);
    if (eol == std::string::npos) eol = content.size();
    std::string line = content.substr(pos, eol - pos);
    pos = eol + 1;
    size_t tab = line.find('\t');
    if (tab == std::string::npos) continue;
    std::string image = line.substr(0, tab);  // e.g. "sing-box.exe"
    DWORD pid = 0;
    for (size_t i = tab + 1; i < line.size(); ++i) {
      char c = line[i];
      if (c < '0' || c > '9') break;
      pid = pid * 10 + static_cast<DWORD>(c - '0');
    }
    if (pid == 0) continue;
    HANDLE p = OpenProcess(
        PROCESS_QUERY_LIMITED_INFORMATION | PROCESS_TERMINATE, FALSE, pid);
    if (!p) continue;
    wchar_t exe[MAX_PATH];
    DWORD sz = MAX_PATH;
    bool match = false;
    if (QueryFullProcessImageNameW(p, 0, exe, &sz)) {
      std::wstring ep(exe);
      std::wstring wimage(image.begin(), image.end());
      if (ep.size() >= wimage.size()) {
        std::wstring tail = ep.substr(ep.size() - wimage.size());
        match = lstrcmpiW(tail.c_str(), wimage.c_str()) == 0;
      }
    }
    if (match) TerminateProcess(p, 0);
    CloseHandle(p);
  }
}

}  // namespace

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  // Recover the user's proxy if a previous run crashed while connected.
  RestoreSystemProxy();

  RECT frame = GetClientArea();

  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  flutter_controller_->engine()->SetNextFrameCallback([&]() { this->Show(); });
  flutter_controller_->ForceRedraw();

  // File channel: native drag-drop events + an open-file dialog over "app/files".
  drop_channel_ = std::make_unique<flutter::MethodChannel<>>(
      flutter_controller_->engine()->messenger(), "app/files",
      &flutter::StandardMethodCodec::GetInstance());
  drop_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<>& call,
             std::unique_ptr<flutter::MethodResult<>> result) {
        if (call.method_name() == "openFile") {
          wchar_t file[MAX_PATH] = {0};
          OPENFILENAMEW ofn = {0};
          ofn.lStructSize = sizeof(ofn);
          ofn.hwndOwner = GetHandle();
          ofn.lpstrFile = file;
          ofn.nMaxFile = MAX_PATH;
          ofn.lpstrFilter =
              L"All files\0*.*\0Configs\0*.txt;*.json;*.conf;*.yaml;*.yml;*.b64\0";
          ofn.Flags = OFN_FILEMUSTEXIST | OFN_PATHMUSTEXIST | OFN_NOCHANGEDIR;
          if (GetOpenFileNameW(&ofn)) {
            result->Success(flutter::EncodableValue(Utf8FromUtf16(file)));
          } else {
            result->Success(flutter::EncodableValue());
          }
        } else if (call.method_name() == "saveFile") {
          wchar_t file[MAX_PATH] = {0};
          if (const auto* args =
                  std::get_if<flutter::EncodableMap>(call.arguments())) {
            const auto it = args->find(flutter::EncodableValue("name"));
            if (it != args->end() &&
                std::holds_alternative<std::string>(it->second)) {
              const std::wstring w =
                  Utf16FromUtf8(std::get<std::string>(it->second));
              wcsncpy_s(file, w.c_str(), _TRUNCATE);
            }
          }
          OPENFILENAMEW ofn = {0};
          ofn.lStructSize = sizeof(ofn);
          ofn.hwndOwner = GetHandle();
          ofn.lpstrFile = file;
          ofn.nMaxFile = MAX_PATH;
          ofn.lpstrFilter = L"JSON\0*.json\0All files\0*.*\0";
          ofn.lpstrDefExt = L"json";
          ofn.Flags = OFN_OVERWRITEPROMPT | OFN_PATHMUSTEXIST | OFN_NOCHANGEDIR;
          if (GetSaveFileNameW(&ofn)) {
            result->Success(flutter::EncodableValue(Utf8FromUtf16(file)));
          } else {
            result->Success(flutter::EncodableValue());
          }
        } else if (call.method_name() == "scanScreenQr") {
          // Whole-screen grab → BMP bytes → Dart runs the existing QR decoder.
          std::vector<uint8_t> bmp = CaptureScreenBmp();
          if (bmp.empty()) {
            result->Success(flutter::EncodableValue());  // null → "no QR"
          } else {
            result->Success(flutter::EncodableValue(std::move(bmp)));
          }
        } else {
          result->NotImplemented();
        }
      });

  // System-proxy channel: point Windows (and proxy-aware apps) at the local
  // sing-box mixed inbound while connected.
  system_channel_ = std::make_unique<flutter::MethodChannel<>>(
      flutter_controller_->engine()->messenger(), "app/system",
      &flutter::StandardMethodCodec::GetInstance());
  system_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<>& call,
             std::unique_ptr<flutter::MethodResult<>> result) {
        if (call.method_name() == "setProxy") {
          std::string server;
          if (const auto* args =
                  std::get_if<flutter::EncodableMap>(call.arguments())) {
            const auto it = args->find(flutter::EncodableValue("server"));
            if (it != args->end() &&
                std::holds_alternative<std::string>(it->second)) {
              server = std::get<std::string>(it->second);
            }
          }
          const bool ok = SetSystemProxy(Utf16FromUtf8(server));
          result->Success(flutter::EncodableValue(ok));
        } else if (call.method_name() == "clearProxy") {
          RestoreSystemProxy();
          result->Success();
        } else if (call.method_name() == "fenceEngage") {
          // EVERY core that dials out (sing-box + each xray bridge) must be
          // permitted, else the fence blacks out XHTTP/Reality-over-XHTTP.
          std::vector<std::wstring> permit_paths;
          if (const auto* args =
                  std::get_if<flutter::EncodableMap>(call.arguments())) {
            const auto it = args->find(flutter::EncodableValue("paths"));
            if (it != args->end()) {
              if (const auto* list =
                      std::get_if<flutter::EncodableList>(&it->second)) {
                for (const auto& v : *list) {
                  if (const auto* s = std::get_if<std::string>(&v)) {
                    permit_paths.push_back(Utf16FromUtf8(*s));
                  }
                }
              }
            }
          }
          // Returns whether the fence is actually up — Dart treats false as
          // "no protection" and must not claim a kill-switch that isn't there.
          result->Success(
              flutter::EncodableValue(KillSwitchEngage(permit_paths)));
        } else if (call.method_name() == "fenceDisengage") {
          KillSwitchDisengage();
          result->Success();
        } else if (call.method_name() == "isElevated") {
          result->Success(flutter::EncodableValue(IsElevated()));
        } else if (call.method_name() == "relaunchElevated") {
          RelaunchElevated();
          result->Success();
        } else if (call.method_name() == "openUrl") {
          std::string url;
          if (const auto* args =
                  std::get_if<flutter::EncodableMap>(call.arguments())) {
            const auto it = args->find(flutter::EncodableValue("url"));
            if (it != args->end() &&
                std::holds_alternative<std::string>(it->second)) {
              url = std::get<std::string>(it->second);
            }
          }
          if (!url.empty()) {
            const std::wstring wurl = Utf16FromUtf8(url);
            ShellExecuteW(nullptr, L"open", wurl.c_str(), nullptr, nullptr,
                          SW_SHOWNORMAL);
          }
          result->Success();
        } else if (call.method_name() == "registerLinkHandlers") {
          RegisterLinkHandlers();
          result->Success();
        } else if (call.method_name() == "unregisterLinkHandlers") {
          UnregisterLinkHandlers();
          result->Success();
        } else if (call.method_name() == "setAutostart") {
          bool on = false, minimized = true;
          if (const auto* args =
                  std::get_if<flutter::EncodableMap>(call.arguments())) {
            const auto it = args->find(flutter::EncodableValue("on"));
            if (it != args->end() && std::holds_alternative<bool>(it->second)) {
              on = std::get<bool>(it->second);
            }
            const auto it2 = args->find(flutter::EncodableValue("minimized"));
            if (it2 != args->end() &&
                std::holds_alternative<bool>(it2->second)) {
              minimized = std::get<bool>(it2->second);
            }
          }
          SetAutostart(on, minimized);
          result->Success();
        } else if (call.method_name() == "isAutostart") {
          result->Success(flutter::EncodableValue(IsAutostartEnabled()));
        } else if (call.method_name() == "setCloseToTray") {
          if (const auto* args =
                  std::get_if<flutter::EncodableMap>(call.arguments())) {
            const auto it = args->find(flutter::EncodableValue("on"));
            if (it != args->end() && std::holds_alternative<bool>(it->second)) {
              close_to_tray_ = std::get<bool>(it->second);
            }
          }
          result->Success();
        } else {
          result->NotImplemented();
        }
      });

  drop_hwnd_ = flutter_controller_->view()->GetNativeWindow();

  // Allow the drag-drop messages across the UIPI boundary so an ELEVATED window
  // (admin — TUN mode) can receive them from the normal-integrity Explorer.
  // Process-global (covers OLE's internal hidden windows) + per-window.
  // WM_COPYGLOBALDATA (0x0049) carries the dragged payload. Harmless when not
  // elevated.
  ::ChangeWindowMessageFilter(WM_DROPFILES, MSGFLT_ADD);
  ::ChangeWindowMessageFilter(WM_COPYDATA, MSGFLT_ADD);
  ::ChangeWindowMessageFilter(0x0049 /* WM_COPYGLOBALDATA */, MSGFLT_ADD);
  for (HWND h : {GetHandle(), drop_hwnd_}) {
    if (!h) continue;
    ::ChangeWindowMessageFilterEx(h, WM_DROPFILES, MSGFLT_ALLOW, nullptr);
    ::ChangeWindowMessageFilterEx(h, WM_COPYDATA, MSGFLT_ALLOW, nullptr);
    ::ChangeWindowMessageFilterEx(h, 0x0049, MSGFLT_ALLOW, nullptr);
  }

  if (IsElevated()) {
    // Admin window: OLE drag-drop is UIPI-blocked (red ✕, no events) and message
    // filters don't fix the COM negotiation. Fall back to the legacy shell
    // file-drop, which DOES cross UIPI — register the view for WM_DROPFILES and
    // subclass it to catch the dropped paths. (No hover overlay here — a Windows
    // limitation for elevated windows — but a config file drops + imports.)
    g_drop_owner = this;
    ::DragAcceptFiles(drop_hwnd_, TRUE);
    g_orig_view_proc = reinterpret_cast<WNDPROC>(::SetWindowLongPtr(
        drop_hwnd_, GWLP_WNDPROC,
        reinterpret_cast<LONG_PTR>(ElevatedDropProc)));
  } else {
    // Normal window: full OLE drop target — files, virtual files, text, AND the
    // drag-enter/leave events that drive the frosted overlay.
    auto* target = new FileDropTarget(this);
    ::RegisterDragDrop(drop_hwnd_, target);
    target->Release();  // OLE keeps its own reference
  }

  StartNetworkWatch();
  AddTrayIcon();  // so close-to-tray has a way back to the window

  return true;
}

void FlutterWindow::StartNetworkWatch() {
  net_stop_ = CreateEventW(nullptr, TRUE, FALSE, nullptr);
  if (!net_stop_) return;
  const HWND hwnd = GetHandle();
  const HANDLE stop = net_stop_;
  net_thread_ = std::thread([hwnd, stop]() {
    OVERLAPPED ov = {};
    ov.hEvent = CreateEventW(nullptr, TRUE, FALSE, nullptr);
    if (!ov.hEvent) return;
    for (;;) {
      ResetEvent(ov.hEvent);
      HANDLE h = nullptr;
      const DWORD ret = NotifyAddrChange(&h, &ov);
      if (ret != ERROR_IO_PENDING && ret != NO_ERROR) break;
      HANDLE waits[2] = {ov.hEvent, stop};
      const DWORD w = WaitForMultipleObjects(2, waits, FALSE, INFINITE);
      if (w != WAIT_OBJECT_0) break;  // stop requested or wait failed
      PostMessageW(hwnd, kNetworkChangedMsg, 0, 0);
    }
    CancelIPChangeNotify(&ov);
    CloseHandle(ov.hEvent);
  });
}

void FlutterWindow::OnFileDropped(const std::string& path) {
  if (drop_channel_ && !path.empty()) {
    drop_channel_->InvokeMethod(
        "onFile", std::make_unique<flutter::EncodableValue>(path));
  }
}

void FlutterWindow::OnContentDropped(const std::vector<uint8_t>& bytes) {
  if (drop_channel_ && !bytes.empty()) {
    drop_channel_->InvokeMethod(
        "onContent", std::make_unique<flutter::EncodableValue>(bytes));
  }
}

void FlutterWindow::OnDragEnter() {
  if (drop_channel_) drop_channel_->InvokeMethod("dragEnter", nullptr);
}

void FlutterWindow::OnDragLeave() {
  if (drop_channel_) drop_channel_->InvokeMethod("dragLeave", nullptr);
}

void FlutterWindow::AddTrayIcon() {
  NOTIFYICONDATAW nid = {};
  nid.cbSize = sizeof(nid);
  nid.hWnd = GetHandle();
  nid.uID = kTrayUid;
  nid.uFlags = NIF_ICON | NIF_MESSAGE | NIF_TIP;
  nid.uCallbackMessage = kTrayMsg;
  nid.hIcon =
      LoadIconW(GetModuleHandleW(nullptr), MAKEINTRESOURCEW(IDI_APP_ICON));
  wcscpy_s(nid.szTip, L"vpn_app");
  tray_added_ = Shell_NotifyIconW(NIM_ADD, &nid) != FALSE;
}

void FlutterWindow::RemoveTrayIcon() {
  if (!tray_added_) return;
  NOTIFYICONDATAW nid = {};
  nid.cbSize = sizeof(nid);
  nid.hWnd = GetHandle();
  nid.uID = kTrayUid;
  Shell_NotifyIconW(NIM_DELETE, &nid);
  tray_added_ = false;
}

void FlutterWindow::ShowFromTray() {
  const HWND hwnd = GetHandle();
  ShowWindow(hwnd, SW_SHOW);
  ShowWindow(hwnd, SW_RESTORE);
  SetForegroundWindow(hwnd);
}

void FlutterWindow::ShowTrayMenu() {
  const HWND hwnd = GetHandle();
  HMENU menu = CreatePopupMenu();
  if (!menu) return;
  AppendMenuW(menu, MF_STRING, kTrayShowCmd, L"Show");
  AppendMenuW(menu, MF_SEPARATOR, 0, nullptr);
  AppendMenuW(menu, MF_STRING, kTrayQuitCmd, L"Quit");
  POINT pt;
  GetCursorPos(&pt);
  // Win32 quirk: the owner must be foreground, and a trailing WM_NULL is needed
  // so the menu dismisses cleanly when the user clicks elsewhere.
  SetForegroundWindow(hwnd);
  TrackPopupMenu(menu, TPM_RIGHTBUTTON, pt.x, pt.y, 0, hwnd, nullptr);
  PostMessageW(hwnd, WM_NULL, 0, 0);
  DestroyMenu(menu);
}

void FlutterWindow::OnDestroy() {
  RemoveTrayIcon();
  if (net_stop_) {
    SetEvent(net_stop_);
    if (net_thread_.joinable()) net_thread_.join();
    CloseHandle(net_stop_);
    net_stop_ = nullptr;
  }
  // Kill our cores + drop the WFP fence FIRST: the Dart onDispose is fire-and-
  // forget and isn't reliably run on process teardown, so without this, closing
  // the window in TUN mode leaves a headless sing-box tunnelling everything.
  KillCoreOrphans();
  KillSwitchDisengage();
  RestoreSystemProxy();  // put the user's proxy back if we changed it
  if (drop_hwnd_) {
    RevokeDragDrop(drop_hwnd_);
    drop_hwnd_ = nullptr;
  }
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case kNetworkChangedMsg:
      if (system_channel_) {
        system_channel_->InvokeMethod("networkChanged", nullptr);
      }
      return 0;
    case WM_POWERBROADCAST:
      // Wake from sleep/hibernate: Windows usually restores the SAME adapter+IP,
      // so NotifyAddrChange never fires even though the tunnel's TCP died during
      // suspend. Nudge Dart to re-probe the tunnel end-to-end and reconnect if
      // it's silently dead (the #1 "opened my laptop, no internet" failure).
      if (wparam == PBT_APMRESUMEAUTOMATIC || wparam == PBT_APMRESUMESUSPEND) {
        if (system_channel_) {
          system_channel_->InvokeMethod("resumed", nullptr);
        }
      }
      break;  // let DefWindowProc grant the broadcast
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
    case WM_ENDSESSION:
      // Logoff / shutdown: WM_DESTROY may not run before we're killed, so reap
      // the cores + fence here too (idempotent with OnDestroy).
      if (wparam) {
        KillCoreOrphans();
        KillSwitchDisengage();
        RestoreSystemProxy();
      }
      break;
    case kTrayMsg:
      // Classic (non-v4) tray callback: lparam carries the mouse message.
      if (LOWORD(lparam) == WM_LBUTTONDBLCLK ||
          LOWORD(lparam) == WM_LBUTTONUP) {
        ShowFromTray();
      } else if (LOWORD(lparam) == WM_RBUTTONUP ||
                 LOWORD(lparam) == WM_CONTEXTMENU) {
        ShowTrayMenu();
      }
      return 0;
    case WM_COMMAND:
      if (LOWORD(wparam) == kTrayShowCmd) {
        ShowFromTray();
        return 0;
      }
      if (LOWORD(wparam) == kTrayQuitCmd) {
        quitting_ = true;  // a REAL quit — let the close destroy + reap cores
        DestroyWindow(hwnd);
        return 0;
      }
      break;
    case WM_CLOSE:
      // Close-to-tray: keep the tunnel alive in the background instead of killing
      // the core. GUARDED by tray_added_ so a failed icon never hides the window
      // with no way back (then it just quits as before).
      if (close_to_tray_ && !quitting_ && tray_added_) {
        ShowWindow(hwnd, SW_HIDE);
        return 0;
      }
      break;
    case WM_COPYDATA: {
      // Warm-start: a second instance forwarded a clicked deeplink/file here
      // (see main.cpp). The OS marshals exactly cbData bytes into our address
      // space, so reading within [0, cbData) is bounds-safe even though ANY local
      // process can post WM_COPYDATA and could lie about the size. We still
      // validate the shape (non-empty, whole wchar_t units) and derive the length
      // by scanning for NUL within the marshaled bound — never assuming the sender
      // NUL-terminated, never reading past cbData. A forwarded deeplink is treated
      // as UNTRUSTED downstream (preview-consent gate), so a forged one can't
      // auto-connect.
      auto* cds = reinterpret_cast<COPYDATASTRUCT*>(lparam);
      if (cds && cds->dwData == kDeeplinkCopyData && cds->lpData &&
          cds->cbData >= sizeof(wchar_t) &&
          cds->cbData % sizeof(wchar_t) == 0) {
        const wchar_t* data = reinterpret_cast<const wchar_t*>(cds->lpData);
        const size_t max_len = cds->cbData / sizeof(wchar_t);
        size_t len = 0;
        while (len < max_len && data[len] != L'\0') len++;
        const std::wstring w(data, len);
        ShowFromTray();
        if (system_channel_ && !w.empty()) {
          system_channel_->InvokeMethod(
              "deeplink", std::make_unique<flutter::EncodableValue>(
                              Utf8FromUtf16(w.c_str())));
        }
      }
      return TRUE;
    }
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
