#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <shellapi.h>
#include <windows.h>

#include <string>

#include "flutter_window.h"
#include "utils.h"

#pragma comment(lib, "shell32.lib")

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // Single instance: a second copy would fight over the local proxy ports
  // (2080/9090) and crash-loop forever. A SESSION-local mutex (no `Global\`,
  // which needs SeCreateGlobalPrivilege a normal user lacks) with a NULL DACL is
  // visible to every process in the session incl. across integrity levels, so an
  // elevated (TUN) copy and a normal copy can't both run. Not the first → focus
  // the existing window and exit.
  {
    SECURITY_DESCRIPTOR sd;
    ::InitializeSecurityDescriptor(&sd, SECURITY_DESCRIPTOR_REVISION);
    ::SetSecurityDescriptorDacl(&sd, TRUE, nullptr, FALSE);  // everyone
    SECURITY_ATTRIBUTES sa = {sizeof(sa), &sd, FALSE};
    ::CreateMutexW(&sa, TRUE, L"vpn_app_single_instance");
    // A deliberate "restart as administrator" relaunch must run even though the
    // outgoing (non-elevated) copy is still alive — it still grabs a handle so
    // future normal launches stay blocked.
    const bool elevated_relaunch =
        command_line && ::wcsstr(command_line, L"--elevated-relaunch");
    if (!elevated_relaunch && ::GetLastError() == ERROR_ALREADY_EXISTS) {
      HWND existing = ::FindWindowW(nullptr, L"vpn_app");
      // Robustness: only act on a window that actually belongs to OUR exe — a
      // title match alone could land on an unrelated window titled "vpn_app".
      if (existing) {
        DWORD pid = 0;
        ::GetWindowThreadProcessId(existing, &pid);
        bool ours = false;
        if (pid) {
          if (HANDLE proc = ::OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION,
                                          FALSE, pid)) {
            wchar_t img[MAX_PATH] = {0};
            DWORD n = MAX_PATH;
            if (::QueryFullProcessImageNameW(proc, 0, img, &n)) {
              const std::wstring s(img);
              ours = s.size() >= 11 &&
                     ::_wcsicmp(s.c_str() + s.size() - 11, L"vpn_app.exe") == 0;
            }
            ::CloseHandle(proc);
          }
        }
        if (!ours) existing = nullptr;
      }
      if (existing) {
        // Warm-start: a clicked deeplink/file while the app is already running
        // would otherwise be LOST — forward the first non-flag argument to the
        // live window (WM_COPYDATA) so it imports there, then focus it.
        int argc = 0;
        if (LPWSTR* argv = ::CommandLineToArgvW(::GetCommandLineW(), &argc)) {
          std::wstring payload;
          for (int i = 1; i < argc; i++) {
            if (argv[i][0] != L'-') {
              payload = argv[i];
              break;
            }
          }
          ::LocalFree(argv);
          if (!payload.empty()) {
            COPYDATASTRUCT cds = {};
            cds.dwData = kDeeplinkCopyData;
            cds.cbData =
                static_cast<DWORD>((payload.size() + 1) * sizeof(wchar_t));
            cds.lpData = const_cast<wchar_t*>(payload.c_str());
            ::SendMessageW(existing, WM_COPYDATA, 0,
                           reinterpret_cast<LPARAM>(&cds));
          }
        }
        ::ShowWindow(existing, SW_RESTORE);
        ::SetForegroundWindow(existing);
      }
      return EXIT_SUCCESS;
    }
  }

  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
  ::OleInitialize(nullptr);  // required for OLE file drag-and-drop

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(440, 700);
  if (!window.Create(L"vpn_app", origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  // Center the compact window on its monitor's work area.
  if (HWND hwnd = window.GetHandle()) {
    RECT rc;
    GetWindowRect(hwnd, &rc);
    const int w = rc.right - rc.left;
    const int h = rc.bottom - rc.top;
    HMONITOR monitor = MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST);
    MONITORINFO mi;
    mi.cbSize = sizeof(MONITORINFO);
    if (GetMonitorInfo(monitor, &mi)) {
      const int x = mi.rcWork.left + (mi.rcWork.right - mi.rcWork.left - w) / 2;
      const int y = mi.rcWork.top + (mi.rcWork.bottom - mi.rcWork.top - h) / 2;
      SetWindowPos(hwnd, nullptr, x, y, 0, 0,
                   SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE);
    }
  }

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::OleUninitialize();
  ::CoUninitialize();
  return EXIT_SUCCESS;
}
