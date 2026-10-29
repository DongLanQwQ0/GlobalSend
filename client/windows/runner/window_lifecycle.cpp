#include "window_lifecycle.h"
#include "resource.h"
#include "single_instance.h"
#include <shellapi.h>
#include <dwmapi.h>
#include <algorithm>
#include <utility>

namespace {
constexpr UINT kTrayMessage = WM_APP + 73;
constexpr UINT kTrayRestore = 731;
constexpr UINT kTrayExit = 732;
constexpr UINT_PTR kSaveTimer = 733;
NOTIFYICONDATAW TrayData(HWND window) {
  NOTIFYICONDATAW data{};
  data.cbSize = sizeof(data);
  data.hWnd = window;
  data.uID = 1;
  return data;
}
}

bool GlobalSendReceiptFullscreen(const RECT& work,
                                 const std::vector<RECT>& app_windows) {
  if (app_windows.empty()) return true;
  if (app_windows.size() != 1) return false;
  const auto& rect = app_windows.front();
  const long long width = rect.right - rect.left;
  const long long height = rect.bottom - rect.top;
  const long long available_width = work.right - work.left;
  const long long available_height = work.bottom - work.top;
  return width * 4 <= available_width * 3 && height * 20 <= available_height * 17 &&
         width * height * 20 <= available_width * available_height * 9;
}

GlobalSendWindowState FitGlobalSendWindow(GlobalSendWindowState state,
                                        const RECT& work) {
  const int available_width = work.right - work.left;
  const int available_height = work.bottom - work.top;
  state.width = std::clamp(state.width, std::min(600, available_width), available_width);
  state.height = std::clamp(state.height, std::min(400, available_height), available_height);
  state.left = std::clamp(state.left, static_cast<int>(work.left),
                          static_cast<int>(work.right) - state.width);
  state.top = std::clamp(state.top, static_cast<int>(work.top),
                         static_cast<int>(work.bottom) - state.height);
  return state;
}

GlobalSendWindowLifecycle::GlobalSendWindowLifecycle(
    HWND window, Visibility visibility, Save save, bool initially_visible)
    : window_(window), visibility_(std::move(visibility)), save_(std::move(save)),
      taskbar_created_(RegisterWindowMessageW(L"TaskbarCreated")), ui_visible_(initially_visible) {
  maximized_ = IsZoomed(window_) != FALSE;
  AddTray();
}

GlobalSendWindowLifecycle::~GlobalSendWindowLifecycle() {
  KillTimer(window_, kSaveTimer);
  if (tray_) {
    auto data = TrayData(window_);
    Shell_NotifyIconW(NIM_DELETE, &data);
  }
}

bool GlobalSendWindowLifecycle::AddTray() {
  auto data = TrayData(window_);
  data.uFlags = NIF_MESSAGE | NIF_ICON | NIF_TIP;
  data.uCallbackMessage = kTrayMessage;
  data.hIcon = LoadIconW(GetModuleHandleW(nullptr), MAKEINTRESOURCEW(IDI_APP_ICON));
  if (!data.hIcon) data.hIcon = LoadIconW(nullptr, IDI_APPLICATION);
  wcscpy_s(data.szTip, L"GlobalSend");
  tray_ = Shell_NotifyIconW(NIM_ADD, &data) != FALSE;
  if (tray_) {
    data.uVersion = NOTIFYICON_VERSION_4;
    Shell_NotifyIconW(NIM_SETVERSION, &data);
  }
  return tray_;
}

bool GlobalSendWindowLifecycle::Visible() const {
  return ui_visible_;
}

void GlobalSendWindowLifecycle::ShowOnFirstFrame() {
  if (ui_visible_) Show();
}

bool GlobalSendWindowLifecycle::ShowReceived() {
  ++receipt_arrival_generation_;
  // Receiving must not change the user's main-window geometry or focus.
  // Background presentation belongs to the independent receive dock.
  return Focused();
}

bool GlobalSendWindowLifecycle::Focused() const {
  return GetAncestor(GetForegroundWindow(), GA_ROOT) == window_ &&
      !IsIconic(window_) && IsWindowVisible(window_);
}

void GlobalSendWindowLifecycle::Activate() { Show(); }

void GlobalSendWindowLifecycle::DismissReceived(std::optional<uint64_t> expected_generation) {
  if (expected_generation && *expected_generation != receipt_arrival_generation_) return;
  if (!receipt_presentation_) return;
  receipt_presentation_ = false;
  Restore(before_receipt_);
}

bool GlobalSendWindowLifecycle::NotifyReceived(const std::wstring& title,
                                              const std::wstring& body, bool update) {
  if (!tray_ && !AddTray()) return false;
  auto data = TrayData(window_);
  data.uFlags = NIF_INFO;
  data.dwInfoFlags = NIIF_INFO | NIIF_RESPECT_QUIET_TIME;
  wcsncpy_s(data.szInfoTitle, title.c_str(), _TRUNCATE);
  wcsncpy_s(data.szInfo, body.c_str(), _TRUNCATE);
  if (!Shell_NotifyIconW(NIM_MODIFY, &data)) return false;
  update_notice_ = update;
  return true;
}

GlobalSendWindowState GlobalSendWindowLifecycle::State() const {
  if (receipt_presentation_) return before_receipt_;
  WINDOWPLACEMENT placement{};
  placement.length = sizeof(placement);
  GetWindowPlacement(window_, &placement);
  RECT normal = placement.rcNormalPosition;
  // WINDOWPLACEMENT uses work-area coordinates for normal top-level windows.
  MONITORINFO monitor{sizeof(monitor)};
  if (GetMonitorInfoW(MonitorFromWindow(window_, MONITOR_DEFAULTTONEAREST), &monitor)) {
    OffsetRect(&normal, monitor.rcWork.left - monitor.rcMonitor.left,
               monitor.rcWork.top - monitor.rcMonitor.top);
  }
  return {normal.left, normal.top, normal.right - normal.left,
          normal.bottom - normal.top,
          maximized_ || placement.showCmd == SW_SHOWMAXIMIZED ||
          (placement.showCmd == SW_SHOWMINIMIZED &&
           (placement.flags & WPF_RESTORETOMAXIMIZED) != 0)};
}

void GlobalSendWindowLifecycle::SaveState() {
  if (!restoring_) save_(State());
}

void GlobalSendWindowLifecycle::Restore(const GlobalSendWindowState& requested) {
  receipt_presentation_ = false;
  RECT rect{requested.left, requested.top, requested.left + requested.width,
            requested.top + requested.height};
  MONITORINFO monitor{sizeof(monitor)};
  if (!GetMonitorInfoW(MonitorFromRect(&rect, MONITOR_DEFAULTTONEAREST), &monitor)) return;
  const auto state = FitGlobalSendWindow(requested, monitor.rcWork);
  maximized_ = state.maximized;
  restoring_ = true;
  WINDOWPLACEMENT placement{};
  placement.length = sizeof(placement);
  placement.showCmd = !ui_visible_ ? SW_HIDE : state.maximized ? SW_SHOWMAXIMIZED : SW_SHOWNORMAL;
  const int dx = monitor.rcWork.left - monitor.rcMonitor.left;
  const int dy = monitor.rcWork.top - monitor.rcMonitor.top;
  placement.rcNormalPosition = {state.left - dx, state.top - dy,
                               state.left + state.width - dx,
                               state.top + state.height - dy};
  SetWindowPlacement(window_, &placement);
  restoring_ = false;
}

void GlobalSendWindowLifecycle::Show() {
  ui_visible_ = true;
  WINDOWPLACEMENT placement{};
  placement.length = sizeof(placement);
  GetWindowPlacement(window_, &placement);
  ShowWindow(window_, maximized_ || placement.showCmd == SW_SHOWMAXIMIZED ||
             (placement.flags & WPF_RESTORETOMAXIMIZED) != 0
                 ? SW_SHOWMAXIMIZED : SW_RESTORE);
  visibility_(true);
  SetForegroundWindow(window_);
}

bool GlobalSendWindowLifecycle::Handle(UINT message, WPARAM wparam,
                                     LPARAM lparam, LRESULT* result) {
  *result = 0;
  if (HandleGlobalSendLaunchMessage(message, lparam, result)) return true;
  if (message == GlobalSendActivateMessage()) {
    Show();
    *result = 1;
    return true;
  }
  if (message == taskbar_created_) {
    tray_ = false;
    AddTray();
    return false;
  }
  switch (message) {
    case WM_CLOSE:
      SaveState();
      DismissReceived();
      // Never strand the process if the shell could not create a tray icon.
      if (!exiting_ && (tray_ || AddTray())) {
        ui_visible_ = false;
        ShowWindow(window_, SW_HIDE);
        visibility_(false);
        return true;
      }
      return false;
    case WM_EXITSIZEMOVE:
      receipt_presentation_ = false;
      SaveState();
      return false;
    case WM_SIZE:
      if (!restoring_ && wparam != SIZE_MINIMIZED) maximized_ = wparam == SIZE_MAXIMIZED;
      if (!restoring_ && wparam != SIZE_MINIMIZED) SetTimer(window_, kSaveTimer, 250, nullptr);
      return false;
    case WM_TIMER:
      if (wparam != kSaveTimer) return false;
      KillTimer(window_, kSaveTimer);
      SaveState();
      return true;
    case WM_QUERYENDSESSION:
      SaveState();
      *result = TRUE;
      return true;
    case kTrayMessage: {
      const UINT action = LOWORD(lparam);
      if (action == NIN_SELECT || action == NIN_KEYSELECT || action == WM_LBUTTONDBLCLK || action == NIN_BALLOONUSERCLICK) {
        Show();
      } else if (action == WM_CONTEXTMENU || action == WM_RBUTTONUP) {
        HMENU menu = CreatePopupMenu();
        AppendMenuW(menu, MF_STRING, kTrayRestore, L"打开 GlobalSend");
        AppendMenuW(menu, MF_SEPARATOR, 0, nullptr);
        AppendMenuW(menu, MF_STRING, kTrayExit, L"退出");
        POINT cursor{};
        GetCursorPos(&cursor);
        SetForegroundWindow(window_);
        const UINT selected = TrackPopupMenu(menu, TPM_RETURNCMD | TPM_NONOTIFY |
            TPM_RIGHTBUTTON, cursor.x, cursor.y, 0, window_, nullptr);
        DestroyMenu(menu);
        PostMessageW(window_, WM_NULL, 0, 0);
        if (selected == kTrayRestore) Show();
        if (selected == kTrayExit) {
          SaveState();
          exiting_ = true;
          PostMessageW(window_, WM_CLOSE, 0, 0);
        }
      }
      return true;
    }
  }
  return false;
}
