#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <flutter/method_channel.h>

#include <cstdint>
#include <memory>
#include <string>
#include <thread>
#include <vector>

#include "win32_window.h"

// WM_COPYDATA tag identifying a forwarded deeplink/file payload from a SECOND
// instance to the running one (warm-start), so a clicked link/config while the
// app is already up isn't lost. Shared by main.cpp (sender) + flutter_window
// (receiver).
constexpr unsigned long kDeeplinkCopyData = 0x56504e31;  // 'VPN1'

// A window that does nothing but host a Flutter view.
class FlutterWindow : public Win32Window {
 public:
  // Creates a new FlutterWindow hosting a Flutter view running |project|.
  explicit FlutterWindow(const flutter::DartProject& project);
  virtual ~FlutterWindow();

 public:
  // Invoked by the OLE drop target registered on the Flutter view.
  void OnFileDropped(const std::string& path);
  void OnContentDropped(const std::vector<uint8_t>& bytes);
  void OnDragEnter();
  void OnDragLeave();

 protected:
  // Win32Window:
  bool OnCreate() override;
  void OnDestroy() override;
  LRESULT MessageHandler(HWND window, UINT const message, WPARAM const wparam,
                         LPARAM const lparam) noexcept override;

 private:
  // The project to run.
  flutter::DartProject project_;

  // The Flutter instance hosted by this window.
  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;

  // Forwards drag events + dropped file paths to Dart.
  std::unique_ptr<flutter::MethodChannel<>> drop_channel_;

  // Sets/clears the Windows system proxy on connect/disconnect.
  std::unique_ptr<flutter::MethodChannel<>> system_channel_;

  // The view window registered as an OLE drop target.
  HWND drop_hwnd_ = nullptr;

  // Watches for network changes (Wi-Fi/Ethernet/IP) to trigger reconnect.
  void StartNetworkWatch();
  std::thread net_thread_;
  HANDLE net_stop_ = nullptr;

  // System tray: close-to-tray keeps the tunnel running in the background when
  // the window is closed (instead of killing the core). The tray icon is the
  // way back. close_to_tray_ defaults true (Dart pushes the real setting on
  // launch); hide-on-close is GUARDED by tray_added_ so a failed icon never
  // leaves the window hidden with no way back.
  void AddTrayIcon();
  void RemoveTrayIcon();
  void ShowFromTray();
  void ShowTrayMenu();
  bool tray_added_ = false;
  bool close_to_tray_ = true;
  bool quitting_ = false;  // a real Quit (tray menu) vs a hide-to-tray close
};

#endif  // RUNNER_FLUTTER_WINDOW_H_
