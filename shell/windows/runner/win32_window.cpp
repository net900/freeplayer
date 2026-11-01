#include "win32_window.h"

#include <dwmapi.h>
#include <flutter_windows.h>

#include "resource.h"

namespace {

/// Window attribute that enables dark mode window decorations.
///
/// Redefined in case the developer's machine has a Windows SDK older than
/// version 10.0.22000.0.
/// See: https://docs.microsoft.com/windows/win32/api/dwmapi/ne-dwmapi-dwmwindowattribute
#ifndef DWMWA_USE_IMMERSIVE_DARK_MODE
#define DWMWA_USE_IMMERSIVE_DARK_MODE 20
#endif

#ifndef DWMWA_BORDER_COLOR
#define DWMWA_BORDER_COLOR 34
#endif

#ifndef DWMWA_COLOR_NONE
#define DWMWA_COLOR_NONE 0xFFFFFFFE
#endif

constexpr const wchar_t kWindowClassName[] = L"FLUTTER_RUNNER_WIN32_WINDOW";

// Timer id for the cursor-driven move/resize loop.
constexpr UINT_PTR kPointerTimerId = 1;
constexpr UINT kPointerTimerIntervalMs = 8;

// Windows may attach a 4px rounded top-corner window region after a resize.
// Window regions are clipped without anti-aliasing, so the corners look
// jagged. A posted message clears it once the resize has fully settled.
constexpr UINT kClearWindowRegionMessage = WM_APP + 1;

/// Registry key for app theme preference.
///
/// A value of 0 indicates apps should use dark mode. A non-zero or missing
/// value indicates apps should use light mode.
constexpr const wchar_t kGetPreferredBrightnessRegKey[] =
  L"Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize";
constexpr const wchar_t kGetPreferredBrightnessRegValue[] = L"AppsUseLightTheme";

// The number of Win32Window objects that currently exist.
static int g_active_window_count = 0;

using EnableNonClientDpiScaling = BOOL __stdcall(HWND hwnd);

// Scale helper to convert logical scaler values to physical using passed in
// scale factor
int Scale(int source, double scale_factor) {
  return static_cast<int>(source * scale_factor);
}

// Dynamically loads the |EnableNonClientDpiScaling| from the User32 module.
// This API is only needed for PerMonitor V1 awareness mode.
void EnableFullDpiSupportIfAvailable(HWND hwnd) {
  HMODULE user32_module = LoadLibraryA("User32.dll");
  if (!user32_module) {
    return;
  }
  auto enable_non_client_dpi_scaling =
      reinterpret_cast<EnableNonClientDpiScaling*>(
          GetProcAddress(user32_module, "EnableNonClientDpiScaling"));
  if (enable_non_client_dpi_scaling != nullptr) {
    enable_non_client_dpi_scaling(hwnd);
  }
  FreeLibrary(user32_module);
}

}  // namespace

// Manages the Win32Window's window class registration.
class WindowClassRegistrar {
 public:
  ~WindowClassRegistrar() = default;

  // Returns the singleton registrar instance.
  static WindowClassRegistrar* GetInstance() {
    if (!instance_) {
      instance_ = new WindowClassRegistrar();
    }
    return instance_;
  }

  // Returns the name of the window class, registering the class if it hasn't
  // previously been registered.
  const wchar_t* GetWindowClass();

  // Unregisters the window class. Should only be called if there are no
  // instances of the window.
  void UnregisterWindowClass();

 private:
  WindowClassRegistrar() = default;

  static WindowClassRegistrar* instance_;

  bool class_registered_ = false;
};

WindowClassRegistrar* WindowClassRegistrar::instance_ = nullptr;

const wchar_t* WindowClassRegistrar::GetWindowClass() {
  if (!class_registered_) {
    WNDCLASS window_class{};
    window_class.hCursor = LoadCursor(nullptr, IDC_ARROW);
    window_class.lpszClassName = kWindowClassName;
    window_class.style = CS_HREDRAW | CS_VREDRAW;
    window_class.cbClsExtra = 0;
    window_class.cbWndExtra = 0;
    window_class.hInstance = GetModuleHandle(nullptr);
    window_class.hIcon =
        LoadIcon(window_class.hInstance, MAKEINTRESOURCE(IDI_APP_ICON));
    window_class.hbrBackground = 0;
    window_class.lpszMenuName = nullptr;
    window_class.lpfnWndProc = Win32Window::WndProc;
    RegisterClass(&window_class);
    class_registered_ = true;
  }
  return kWindowClassName;
}

void WindowClassRegistrar::UnregisterWindowClass() {
  UnregisterClass(kWindowClassName, nullptr);
  class_registered_ = false;
}

Win32Window::Win32Window() {
  ++g_active_window_count;
}

Win32Window::~Win32Window() {
  --g_active_window_count;
  Destroy();
}

bool Win32Window::Create(const std::wstring& title,
                         const Point& origin,
                         const Size& size) {
  Destroy();

  const wchar_t* window_class =
      WindowClassRegistrar::GetInstance()->GetWindowClass();

  const POINT target_point = {static_cast<LONG>(origin.x),
                              static_cast<LONG>(origin.y)};
  HMONITOR monitor = MonitorFromPoint(target_point, MONITOR_DEFAULTTONEAREST);
  UINT dpi = FlutterDesktopGetDpiForMonitor(monitor);
  double scale_factor = dpi / 96.0;

  // Keep the standard overlapped styles so DWM still runs its native
  // maximize/restore animation (a WS_POPUP window is skipped by the
  // compositor and snaps instantly). WM_NCCALCSIZE below makes the client
  // cover the whole window, so no caption or frame is ever visible.
  const DWORD style = WS_OVERLAPPEDWINDOW;
  const int left = Scale(origin.x, scale_factor);
  const int top = Scale(origin.y, scale_factor);
  const int width = Scale(size.width, scale_factor);
  const int height = Scale(size.height, scale_factor);
  initial_rect_ = {left, top, left + width, top + height};

  HWND window = CreateWindowEx(
      WS_EX_APPWINDOW, window_class, title.c_str(), style, left, top, width,
      height, nullptr, nullptr, GetModuleHandle(nullptr), this);

  if (!window) {
    return false;
  }

  // No title bar or frame is drawn by the OS. Non-client rendering is
  // disabled to suppress the DWM border/shadow; the standard styles are kept
  // so the compositor still animates maximize/restore.
  DWMNCRENDERINGPOLICY policy = DWMNCRP_DISABLED;
  DwmSetWindowAttribute(window, DWMWA_NCRENDERING_POLICY, &policy,
                        sizeof(policy));
  const DWORD no_border = DWMWA_COLOR_NONE;
  DwmSetWindowAttribute(window, DWMWA_BORDER_COLOR, &no_border,
                        sizeof(no_border));

  UpdateTheme(window);

  return OnCreate();
}

bool Win32Window::Show() {
  if (window_handle_ == nullptr) {
    return false;
  }
  // Windows may restore a remembered maximized placement for the executable;
  // always start at the requested normal rect.
  SetWindowPos(window_handle_, nullptr, initial_rect_.left, initial_rect_.top,
               initial_rect_.right - initial_rect_.left,
               initial_rect_.bottom - initial_rect_.top,
               SWP_NOZORDER | SWP_NOACTIVATE);
  SetWindowRgn(window_handle_, nullptr, TRUE);
  return ShowWindow(window_handle_, SW_SHOWNORMAL);
}

// static
LRESULT CALLBACK Win32Window::WndProc(HWND const window,
                                      UINT const message,
                                      WPARAM const wparam,
                                      LPARAM const lparam) noexcept {
  if (message == WM_NCCREATE) {
    auto window_struct = reinterpret_cast<CREATESTRUCT*>(lparam);
    SetWindowLongPtr(window, GWLP_USERDATA,
                     reinterpret_cast<LONG_PTR>(window_struct->lpCreateParams));

    auto that = static_cast<Win32Window*>(window_struct->lpCreateParams);
    EnableFullDpiSupportIfAvailable(window);
    that->window_handle_ = window;
  } else if (Win32Window* that = GetThisFromHandle(window)) {
    return that->MessageHandler(window, message, wparam, lparam);
  }

  return DefWindowProc(window, message, wparam, lparam);
}

LRESULT
Win32Window::MessageHandler(HWND hwnd,
                            UINT const message,
                            WPARAM const wparam,
                            LPARAM const lparam) noexcept {
  switch (message) {
    case WM_GETMINMAXINFO: {
      // A frameless window would otherwise shrink until the shell layout
      // clips and the resize edge disappears.
      auto* info = reinterpret_cast<MINMAXINFO*>(lparam);
      HMONITOR monitor = MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST);
      UINT dpi = FlutterDesktopGetDpiForMonitor(monitor);
      const double scale = dpi / 96.0;
      info->ptMinTrackSize.x = static_cast<LONG>(960 * scale);
      info->ptMinTrackSize.y = static_cast<LONG>(640 * scale);
      return 0;
    }

    case WM_NCCALCSIZE:
      if (wparam == TRUE) {
        auto* params = reinterpret_cast<NCCALCSIZE_PARAMS*>(lparam);
        // Always claim the whole window as client so no non-client frame
        // exists for Windows 10 to paint. A maximized window is inflated past
        // the work area by the resize frame, so fit its client to the monitor
        // work area; otherwise DefWindowProc leaves that strip as a light
        // 1px border (DWMWA_BORDER_COLOR only exists on Windows 11).
        if (IsZoomed(hwnd)) {
          HMONITOR monitor = MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST);
          MONITORINFO info{};
          info.cbSize = sizeof(info);
          if (GetMonitorInfo(monitor, &info)) {
            params->rgrc[0] = info.rcWork;
          } else {
            const int frame_x = GetSystemMetrics(SM_CXSIZEFRAME) +
                                GetSystemMetrics(SM_CXPADDEDBORDER);
            const int frame_y = GetSystemMetrics(SM_CYSIZEFRAME) +
                                GetSystemMetrics(SM_CXPADDEDBORDER);
            params->rgrc[0].left += frame_x;
            params->rgrc[0].top += frame_y;
            params->rgrc[0].right -= frame_x;
            params->rgrc[0].bottom -= frame_y;
          }
        }
        return 0;
      }
      break;

    case WM_NCACTIVATE:
      // There is no frame to redraw on activation; letting the default
      // handler run repaints a border strip on Windows 10.
      return TRUE;

    case WM_NCPAINT:
      return 0;

    case WM_TIMER:
      if (wparam == kPointerTimerId && pointer_mode_ != PointerMode::kNone) {
        ApplyPointer();
        if ((GetAsyncKeyState(VK_LBUTTON) & 0x8000) == 0) {
          StopPointer();
        }
        return 0;
      }
      break;

    case WM_DESTROY:
      StopPointer();
      window_handle_ = nullptr;
      Destroy();
      if (quit_on_close_) {
        PostQuitMessage(0);
      }
      return 0;

    case WM_DPICHANGED: {
      auto newRectSize = reinterpret_cast<RECT*>(lparam);
      LONG newWidth = newRectSize->right - newRectSize->left;
      LONG newHeight = newRectSize->bottom - newRectSize->top;

      SetWindowPos(hwnd, nullptr, newRectSize->left, newRectSize->top, newWidth,
                   newHeight, SWP_NOZORDER | SWP_NOACTIVATE);

      return 0;
    }
    case WM_SIZE: {
      RECT rect = GetClientArea();
      if (child_content_ != nullptr) {
        // Size and position the child window.
        MoveWindow(child_content_, rect.left, rect.top, rect.right - rect.left,
                   rect.bottom - rect.top, TRUE);
      }
      // Windows applies a 4px top-corner window region after some resizes,
      // which clips the corners with hard, aliased edges. Keep the window a
      // plain rectangle so nothing is cut off.
      SetWindowRgn(hwnd, nullptr, TRUE);
      PostMessage(hwnd, kClearWindowRegionMessage, 0, 0);
      return 0;
    }

    case kClearWindowRegionMessage:
      SetWindowRgn(hwnd, nullptr, TRUE);
      return 0;

    case WM_ACTIVATE:
      if (child_content_ != nullptr) {
        SetFocus(child_content_);
      }
      return 0;

    case WM_DWMCOLORIZATIONCOLORCHANGED:
      UpdateTheme(hwnd);
      return 0;
  }

  return DefWindowProc(window_handle_, message, wparam, lparam);
}

void Win32Window::Destroy() {
  OnDestroy();

  if (window_handle_) {
    DestroyWindow(window_handle_);
    window_handle_ = nullptr;
  }
  if (g_active_window_count == 0) {
    WindowClassRegistrar::GetInstance()->UnregisterWindowClass();
  }
}

Win32Window* Win32Window::GetThisFromHandle(HWND const window) noexcept {
  return reinterpret_cast<Win32Window*>(
      GetWindowLongPtr(window, GWLP_USERDATA));
}

void Win32Window::SetChildContent(HWND content) {
  child_content_ = content;
  SetParent(content, window_handle_);
  RECT frame = GetClientArea();

  MoveWindow(content, frame.left, frame.top, frame.right - frame.left,
             frame.bottom - frame.top, true);

  SetFocus(child_content_);
}

RECT Win32Window::GetClientArea() {
  RECT frame;
  GetClientRect(window_handle_, &frame);
  return frame;
}

HWND Win32Window::GetHandle() {
  return window_handle_;
}

void Win32Window::SetQuitOnClose(bool quit_on_close) {
  quit_on_close_ = quit_on_close;
}

void Win32Window::BeginDrag() {
  if (pointer_mode_ != PointerMode::kNone || window_handle_ == nullptr) {
    return;
  }
  if (IsZoomed(window_handle_)) {
    ShowWindow(window_handle_, SW_RESTORE);
  }
  POINT cursor;
  if (!GetCursorPos(&cursor)) {
    return;
  }
  GetWindowRect(window_handle_, &pointer_start_rect_);
  pointer_origin_ = cursor;
  pointer_mode_ = PointerMode::kMove;
  if (pointer_timer_ == 0) {
    pointer_timer_ =
        SetTimer(window_handle_, kPointerTimerId, kPointerTimerIntervalMs,
                 nullptr);
  }
}

void Win32Window::BeginResize(const std::string& edge) {
  if (pointer_mode_ != PointerMode::kNone || window_handle_ == nullptr) {
    return;
  }
  POINT cursor;
  if (!GetCursorPos(&cursor)) {
    return;
  }
  GetWindowRect(window_handle_, &pointer_start_rect_);
  pointer_origin_ = cursor;
  resize_edge_ = edge;
  pointer_mode_ = PointerMode::kResize;
  if (pointer_timer_ == 0) {
    pointer_timer_ =
        SetTimer(window_handle_, kPointerTimerId, kPointerTimerIntervalMs,
                 nullptr);
  }
}

void Win32Window::ApplyPointer() {
  if (window_handle_ == nullptr || pointer_mode_ == PointerMode::kNone) {
    return;
  }
  POINT cursor;
  if (!GetCursorPos(&cursor)) {
    return;
  }
  const int dx = cursor.x - pointer_origin_.x;
  const int dy = cursor.y - pointer_origin_.y;
  if (pointer_mode_ == PointerMode::kMove) {
    SetWindowPos(window_handle_, nullptr, pointer_start_rect_.left + dx,
                 pointer_start_rect_.top + dy, 0, 0,
                 SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE);
    return;
  }
  RECT rect = pointer_start_rect_;
  const bool left = resize_edge_.find("left") != std::string::npos;
  const bool right = resize_edge_.find("right") != std::string::npos;
  const bool top = resize_edge_.find("top") != std::string::npos;
  const bool bottom = resize_edge_.find("bottom") != std::string::npos;
  if (left) rect.left += dx;
  if (right) rect.right += dx;
  if (top) rect.top += dy;
  if (bottom) rect.bottom += dy;
  constexpr int kMinWidth = 640;
  constexpr int kMinHeight = 480;
  if (rect.right - rect.left < kMinWidth) {
    if (left) {
      rect.left = rect.right - kMinWidth;
    } else {
      rect.right = rect.left + kMinWidth;
    }
  }
  if (rect.bottom - rect.top < kMinHeight) {
    if (top) {
      rect.top = rect.bottom - kMinHeight;
    } else {
      rect.bottom = rect.top + kMinHeight;
    }
  }
  SetWindowPos(window_handle_, nullptr, rect.left, rect.top,
               rect.right - rect.left, rect.bottom - rect.top,
               SWP_NOZORDER | SWP_NOACTIVATE);
}

void Win32Window::StopPointer() {
  pointer_mode_ = PointerMode::kNone;
  if (pointer_timer_ != 0) {
    KillTimer(window_handle_, kPointerTimerId);
    pointer_timer_ = 0;
  }
}


bool Win32Window::OnCreate() {
  // No-op; provided for subclasses.
  return true;
}

void Win32Window::OnDestroy() {
  // No-op; provided for subclasses.
}

void Win32Window::UpdateTheme(HWND const window) {
  DWORD light_mode;
  DWORD light_mode_size = sizeof(light_mode);
  LSTATUS result = RegGetValue(HKEY_CURRENT_USER, kGetPreferredBrightnessRegKey,
                               kGetPreferredBrightnessRegValue,
                               RRF_RT_REG_DWORD, nullptr, &light_mode,
                               &light_mode_size);

  if (result == ERROR_SUCCESS) {
    BOOL enable_dark_mode = light_mode == 0;
    DwmSetWindowAttribute(window, DWMWA_USE_IMMERSIVE_DARK_MODE,
                          &enable_dark_mode, sizeof(enable_dark_mode));
  }
}
