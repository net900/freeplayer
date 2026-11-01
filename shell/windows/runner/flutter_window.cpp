#include "flutter_window.h"

#include <flutter/standard_method_codec.h>

#include <optional>

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

  window_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(), "free_player/window",
          &flutter::StandardMethodCodec::GetInstance());
  window_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                 result) {
        HWND hwnd = GetHandle();
        const std::string& method = call.method_name();
        if (method == "drag") {
          BeginDrag();
          result->Success();
        } else if (method == "startResize") {
          std::string edge;
          if (const auto* args =
                  std::get_if<flutter::EncodableMap>(call.arguments())) {
            auto it = args->find(flutter::EncodableValue("edge"));
            if (it != args->end()) {
              if (const auto* v = std::get_if<std::string>(&it->second)) {
                edge = *v;
              }
            }
          }
          BeginResize(edge);
          result->Success();
        } else if (method == "minimize") {
          ShowWindow(hwnd, SW_MINIMIZE);
          result->Success();
        } else if (method == "toggleMaximize") {
          ShowWindow(hwnd, IsZoomed(hwnd) ? SW_RESTORE : SW_MAXIMIZE);
          result->Success(flutter::EncodableValue(IsZoomed(hwnd) != 0));
        } else if (method == "isMaximized") {
          result->Success(flutter::EncodableValue(IsZoomed(hwnd) != 0));
        } else if (method == "setFullscreen") {
          bool on = false;
          if (const auto* args =
                  std::get_if<flutter::EncodableMap>(call.arguments())) {
            auto it = args->find(flutter::EncodableValue("on"));
            if (it != args->end()) {
              if (const auto* v = std::get_if<bool>(&it->second)) {
                on = *v;
              }
            }
          }
          SetFullscreen(hwnd, on);
          result->Success(flutter::EncodableValue(fullscreen_));
        } else if (method == "close") {
          PostMessage(hwnd, WM_CLOSE, 0, 0);
          result->Success();
        } else if (method == "activate") {
          // A second launch asks the running window to come forward instead
          // of opening another one.
          if (IsIconic(hwnd)) {
            ShowWindow(hwnd, SW_RESTORE);
          } else {
            ShowWindow(hwnd, SW_SHOW);
          }
          if (!SetForegroundWindow(hwnd)) {
            // Windows refuses foreground changes from background processes;
            // a brief top-most hop is the usual way to take it anyway.
            SetWindowPos(hwnd, HWND_TOPMOST, 0, 0, 0, 0,
                         SWP_NOMOVE | SWP_NOSIZE | SWP_SHOWWINDOW);
            SetWindowPos(hwnd, HWND_NOTOPMOST, 0, 0, 0, 0,
                         SWP_NOMOVE | SWP_NOSIZE | SWP_SHOWWINDOW);
            SetForegroundWindow(hwnd);
          }
          BringWindowToTop(hwnd);
          result->Success();
        } else {
          result->NotImplemented();
        }
      });

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

void FlutterWindow::SetFullscreen(HWND hwnd, bool on) {
  if (on == fullscreen_) {
    return;
  }
  if (on) {
    saved_placement_.length = sizeof(saved_placement_);
    GetWindowPlacement(hwnd, &saved_placement_);
    saved_style_ = GetWindowLong(hwnd, GWL_STYLE);
    MONITORINFO mi = {sizeof(mi)};
    if (GetMonitorInfo(MonitorFromWindow(hwnd, MONITOR_DEFAULTTOPRIMARY), &mi)) {
      SetWindowLong(hwnd, GWL_STYLE, saved_style_ & ~WS_OVERLAPPEDWINDOW);
      SetWindowPos(hwnd, HWND_TOP, mi.rcMonitor.left, mi.rcMonitor.top,
                   mi.rcMonitor.right - mi.rcMonitor.left,
                   mi.rcMonitor.bottom - mi.rcMonitor.top,
                   SWP_NOOWNERZORDER | SWP_FRAMECHANGED);
    }
  } else {
    SetWindowLong(hwnd, GWL_STYLE, saved_style_);
    SetWindowPlacement(hwnd, &saved_placement_);
    SetWindowPos(hwnd, nullptr, 0, 0, 0, 0,
                 SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_NOOWNERZORDER |
                     SWP_FRAMECHANGED);
  }
  fullscreen_ = on;
}

void FlutterWindow::OnDestroy() {
  window_channel_ = nullptr;
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
