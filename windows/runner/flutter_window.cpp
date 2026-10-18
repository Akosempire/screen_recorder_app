#include "flutter_window.h"

#include <flutter/standard_method_codec.h>

#include <optional>

#ifndef WDA_EXCLUDEFROMCAPTURE
#define WDA_EXCLUDEFROMCAPTURE 0x00000011
#endif

#include "flutter/generated_plugin_registrant.h"

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  RegisterWindowsChannel();

  // Keep this app's own window (home screen, recording controls) out of
  // screen captures. Supported on Windows 10 2004+; ignored elsewhere.
  SetWindowDisplayAffinity(GetHandle(), WDA_EXCLUDEFROMCAPTURE);
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::RegisterWindowsChannel() {
  windows_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(),
          "screen_recorder_app/windows",
          &flutter::StandardMethodCodec::GetInstance());
  windows_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                 result) {
        const std::string& method = call.method_name();
        if (method == "showCursorOverlay") {
          bool halo = true;
          bool ripples = true;
          if (const auto* args =
                  std::get_if<flutter::EncodableMap>(call.arguments())) {
            auto read = [args](const char* key, bool fallback) {
              auto it = args->find(flutter::EncodableValue(key));
              if (it == args->end()) return fallback;
              const auto* value = std::get_if<bool>(&it->second);
              return value ? *value : fallback;
            };
            halo = read("halo", true);
            ripples = read("ripples", true);
          }
          result->Success(
              flutter::EncodableValue(cursor_overlay_.Show(halo, ripples)));
        } else if (method == "hideCursorOverlay") {
          cursor_overlay_.Hide();
          result->Success(flutter::EncodableValue(true));
        } else if (method == "getMonitorRect") {
          HMONITOR monitor =
              MonitorFromWindow(GetHandle(), MONITOR_DEFAULTTOPRIMARY);
          MONITORINFO info = {};
          info.cbSize = sizeof(info);
          if (!monitor || !GetMonitorInfo(monitor, &info)) {
            result->Error("unavailable", "GetMonitorInfo failed");
            return;
          }
          const RECT& r = info.rcMonitor;
          flutter::EncodableMap map;
          map[flutter::EncodableValue("x")] =
              flutter::EncodableValue(static_cast<int32_t>(r.left));
          map[flutter::EncodableValue("y")] =
              flutter::EncodableValue(static_cast<int32_t>(r.top));
          map[flutter::EncodableValue("width")] =
              flutter::EncodableValue(static_cast<int32_t>(r.right - r.left));
          map[flutter::EncodableValue("height")] =
              flutter::EncodableValue(static_cast<int32_t>(r.bottom - r.top));
          result->Success(flutter::EncodableValue(map));
        } else {
          result->NotImplemented();
        }
      });
}

void FlutterWindow::OnDestroy() {
  cursor_overlay_.Hide();
  windows_channel_ = nullptr;
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
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
