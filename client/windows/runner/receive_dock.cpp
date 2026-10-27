#include "receive_dock.h"
#include "touch_drag.h"
#include "drop_target.h"
#include "shell_file.h"
#include <flutter/standard_method_codec.h>
#include <flutter_windows.h>
#include <dwmapi.h>
#include <algorithm>
#include <utility>

namespace {
using Value = flutter::EncodableValue;
constexpr UINT kFrameReady = WM_APP + 124;
constexpr UINT kDragFinished = WM_APP + 125;
constexpr UINT_PTR kAnimation = 41;
constexpr UINT_PTR kMovePointer = 42;
uintptr_t next_frame_token = 0;
void TransparentComposition(HWND window) {
  // No system backdrop: it paints the entire HWND, including Flutter's clear
  // pixels. Keep composition alpha instead of a grey acrylic rectangle.
  const DWORD no_backdrop = 1;
  DwmSetWindowAttribute(window, 38, &no_backdrop, sizeof(no_backdrop));
  const MARGINS margins{0, 0, 1, 0};
  DwmExtendFrameIntoClientArea(window, &margins);
  struct AccentPolicy { int state; DWORD flags, color, animation; };
  struct CompositionData { int attribute; void* data; SIZE_T size; };
  using SetComposition = BOOL(WINAPI*)(HWND, CompositionData*);
  const auto set_composition = reinterpret_cast<SetComposition>(
      GetProcAddress(GetModuleHandleW(L"user32.dll"), "SetWindowCompositionAttribute"));
  if (set_composition) {
    AccentPolicy accent{2, 2, 0, 0};  // transparent gradient, alpha zero
    CompositionData data{19, &accent, sizeof(accent)};
    set_composition(window, &data);
  }
}
int64_t Number(const flutter::EncodableMap& map, const char* key) {
  const auto found = map.find(Value(key));
  if (found == map.end()) return 0;
  if (const auto* value = std::get_if<int64_t>(&found->second)) return *value;
  if (const auto* value = std::get_if<int>(&found->second)) return *value;
  return 0;
}
}

GlobalSendReceiveDock::GlobalSendReceiveDock(Map payload, Action action,
    Drag drag, std::function<void()> shown, std::function<void(int64_t)> closed)
    : payload_(std::move(payload)), action_(std::move(action)), drag_(std::move(drag)),
      first_frame_(std::move(shown)), closed_(std::move(closed)), frame_token_(++next_frame_token), instance_token_(frame_token_) {}

GlobalSendReceiveDock::~GlobalSendReceiveDock() { Destroy(); }

int64_t GlobalSendReceiveDock::Generation() const { return Number(payload_, "arrivalGeneration"); }

bool GlobalSendReceiveDock::Open() {
  return Create(L"GlobalSend 接收坞", Point(0, 0), Size(480, 184),
      WS_POPUP | WS_CLIPCHILDREN, WS_EX_TOOLWINDOW | WS_EX_TOPMOST);
}

void GlobalSendReceiveDock::Position() {
  const auto entries = payload_.find(Value("items"));
  const bool multiple = entries != payload_.end() &&
      std::get_if<flutter::EncodableList>(&entries->second) &&
      std::get<flutter::EncodableList>(entries->second).size() > 1;
  MONITORINFO monitor{sizeof(monitor)};
  const auto target = MonitorFromWindow(GetForegroundWindow(), MONITOR_DEFAULTTOPRIMARY);
  if (!GetMonitorInfoW(target, &monitor)) return;
  const auto bounds = GlobalSendReceiveDockBounds(monitor.rcWork, FlutterDesktopGetDpiForMonitor(target), multiple);
  resting_ = bounds;
  SetWindowPos(GetHandle(), HWND_TOPMOST, bounds.left, bounds.top,
      bounds.right - bounds.left, bounds.bottom - bounds.top, SWP_NOACTIVATE);
}

bool GlobalSendReceiveDock::OnCreate() {
  const HWND window = GetHandle();
  // Let DWM compose the outer curve and shadow. A binary window region would
  // produce jagged corners and disable system antialiasing.
  constexpr DWORD corner_preference = 33;
  const DWORD rounded = 2;
  DwmSetWindowAttribute(window, corner_preference, &rounded, sizeof(rounded));
  const DWORD no_border = 0xfffffffe;
  DwmSetWindowAttribute(window, 34, &no_border, sizeof(no_border));
  TransparentComposition(window);
  Position();
  const auto rect = GetClientArea();
  flutter::DartProject project(L"data");
  project.set_dart_entrypoint_arguments({"--receive-dock"});
  controller_ = std::make_unique<flutter::FlutterViewController>(
      rect.right - rect.left, rect.bottom - rect.top, project);
  if (!controller_->engine() || !controller_->view()) return false;
  system_channel_ = std::make_unique<flutter::MethodChannel<Value>>(
      controller_->engine()->messenger(), "dev.globalsend/system",
      &flutter::StandardMethodCodec::GetInstance());
  system_channel_->SetMethodCallHandler([this](const auto& call, auto result) {
    if (call.method_name() != "openWebUrl") { result->NotImplemented(); return; }
    const auto* args = call.arguments() ? std::get_if<Map>(call.arguments()) : nullptr;
    const auto found = args ? args->find(Value("url")) : Map::const_iterator{};
    const auto* url = args && found != args->end() ? std::get_if<std::string>(&found->second) : nullptr;
    const auto status = url ? OpenGlobalSendWebUrl(GetHandle(), *url) : E_INVALIDARG;
    if (status == E_INVALIDARG) result->Error("INVALID_URL", "网址无效");
    else if (SUCCEEDED(status)) result->Success();
    else result->Error("OPEN_URL_FAILED", "无法打开网址");
  });
  channel_ = std::make_unique<flutter::MethodChannel<Value>>(
      controller_->engine()->messenger(), "dev.globalsend/receive-dock",
      &flutter::StandardMethodCodec::GetInstance());
  channel_->SetMethodCallHandler([this](const auto& call, auto result) {
    if (call.method_name() == "ready") { result->Success(Value(payload_)); return; }
    if (call.method_name() == "hitRegions") {
      // One translucent pane includes the gaps between cards. Leave its native
      // region unset so DWM antialiases the outer corners without repeated cuts.
      result->Success();
      return;
    }
    if (call.method_name() == "presented") {
      result->Success();
      if (shown_ || presentation_scheduled_) return;
      presentation_scheduled_ = true;
      const HWND handle = GetHandle();
      const auto token = frame_token_;
      controller_->engine()->SetNextFrameCallback([handle, token]() {
        PostMessageW(handle, kFrameReady, token, 0);
      });
      controller_->ForceRedraw();
      return;
    }
    if (call.method_name() == "move") {
      const auto* arguments = call.arguments() ? std::get_if<Map>(call.arguments()) : nullptr;
      result->Success();
      if (arguments) BeginMove(*arguments);
      return;
    }
    if (call.method_name() == "dragOut") {
      const auto* arguments = call.arguments() ? std::get_if<Map>(call.arguments()) : nullptr;
      if (!arguments || !drag_) { result->Error("BAD_ARGUMENT", "Expected drag data"); return; }
      dragging_ = true;
      const HWND handle = GetHandle();
      const auto instance = instance_token_;
      auto reply = std::make_unique<GlobalSendDockDragReply>(std::move(result), [handle, instance] {
        PostMessageW(handle, kDragFinished, instance, 0);
      });
      drag_(*arguments, std::move(reply), handle);
      return;
    }
    if (call.method_name() == "action") {
      const auto* arguments = call.arguments() ? std::get_if<Map>(call.arguments()) : nullptr;
      if (!arguments) { result->Error("BAD_ARGUMENT", "Expected dock action"); return; }
      const auto action = *arguments;
      result->Success();
      if (action_) action_(action);
      return;
    }
    result->NotImplemented();
  });
  const HWND view = controller_->view()->GetNativeWindow();
  SetChildContent(view, false);
  AttachGlobalSendTouchDragWindow(view, window);
  // A native export may re-enter this display-only surface. Keep the Shell
  // drag image alive there, while reserving actual local drops for main's queue.
  drop_target_ = CreateGlobalSendDropTarget({[](bool) {}, [](GlobalSendDroppedContent) {},
      [] { return true; }, [](POINTL) { return false; }}, window);
  for (const HWND target : {view, window}) {
    if (SUCCEEDED(RegisterDragDrop(target, drop_target_))) drop_windows_.push_back(target);
  }
  // Dart acknowledges a content-bearing layout before the native first-frame
  // gate is armed. The engine's initial empty frame must never flash on screen.
  controller_->ForceRedraw();
  return true;
}

void GlobalSendReceiveDock::Update(Map payload) {
  const bool fresh_arrival = Number(payload, "arrivalGeneration") != Generation();
  const bool reveal = fresh_arrival && !shown_ && closing_finished_;
  if ((closing_ || closing_finished_) && !fresh_arrival) return;
  if (fresh_arrival && (closing_ || closing_finished_)) {
    KillTimer(GetHandle(), kAnimation);
    closing_ = closing_finished_ = false;
    SetWindowPos(GetHandle(), nullptr, resting_.left, resting_.top, 0, 0,
        SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE);
    if (reveal) {
      presentation_scheduled_ = false;
      frame_token_ = ++next_frame_token;
      payload[Value("reveal")] = Value(true);
    }
  }
  payload_ = std::move(payload);
  if (channel_) channel_->InvokeMethod("content", std::make_unique<Value>(payload_));
}

void GlobalSendReceiveDock::HideAnimated() {
  if (!GetHandle() || closing_) return;
  if (moving_) EndMove();
  if (shown_) Animate(true);
  else {
    closing_finished_ = true;
    if (closed_) closed_(Generation());
  }
}

void GlobalSendReceiveDock::BeginMove(const Map& args) {
  if (closing_ || dragging_ || moving_) return;
  KillTimer(GetHandle(), kAnimation);
  GetWindowRect(GetHandle(), &move_start_);
  move_anchor_ = {move_start_.left + static_cast<LONG>(Number(args, "x")),
      move_start_.top + static_cast<LONG>(Number(args, "y"))};
  const auto touch = args.find(Value("touch"));
  moving_touch_ = touch != args.end() && std::get_if<bool>(&touch->second) && std::get<bool>(touch->second);
  moving_ = true;
  if (!moving_touch_) SetCapture(GetHandle());
  SetTimer(GetHandle(), kMovePointer, 15, nullptr);
  TickMove();
}

void GlobalSendReceiveDock::TickMove() {
  if (!moving_) return;
  POINT point{};
  bool held;
  if (moving_touch_) held = GlobalSendHeldTouchPoint(GetHandle(), &point);
  else {
    if (!GetCursorPos(&point)) { EndMove(); return; }
    held = (GetAsyncKeyState(VK_LBUTTON) & 0x8000) != 0;
  }
  if (!moving_touch_ || held) {
    const auto origin = GlobalSendReceiveDockMoveOrigin(move_start_, move_anchor_, point);
    SetWindowPos(GetHandle(), nullptr, origin.x, origin.y, 0, 0,
        SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE);
  }
  if (!held) EndMove();
}

void GlobalSendReceiveDock::EndMove() {
  moving_ = false;
  KillTimer(GetHandle(), kMovePointer);
  if (GetCapture() == GetHandle()) ReleaseCapture();
  GetWindowRect(GetHandle(), &resting_);
  if (channel_) channel_->InvokeMethod("interactionEnded", nullptr);
  if (closing_finished_ && closed_) closed_(Generation());
}

void GlobalSendReceiveDock::Animate(bool closing) {
  closing_ = closing;
  closing_finished_ = false;
  RECT current{};
  GetWindowRect(GetHandle(), &current);
  MONITORINFO monitor{sizeof(monitor)};
  GetMonitorInfoW(MonitorFromWindow(GetHandle(), MONITOR_DEFAULTTONEAREST), &monitor);
  const int offscreen = std::max(resting_.right, monitor.rcWork.right) + MulDiv(20, GetDpiForWindow(GetHandle()), 96);
  animation_from_ = closing ? current.left : offscreen;
  animation_to_ = closing ? offscreen : resting_.left;
  animation_start_ = GetTickCount64();
  SetWindowPos(GetHandle(), nullptr, animation_from_, resting_.top, 0, 0,
      SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE);
  ShowWindow(GetHandle(), SW_SHOWNOACTIVATE);
  SetTimer(GetHandle(), kAnimation, 15, nullptr);
}

void GlobalSendReceiveDock::Tick() {
  const double t = std::min(1.0, (GetTickCount64() - animation_start_) / (closing_ ? 230.0 : 300.0));
  const double eased = closing_ ? t * t * t : 1 - (1 - t) * (1 - t) * (1 - t);
  const int x = animation_from_ + static_cast<int>((animation_to_ - animation_from_) * eased);
  SetWindowPos(GetHandle(), nullptr, x, resting_.top, 0, 0,
      SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE);
  if (t < 1) return;
  KillTimer(GetHandle(), kAnimation);
  if (closing_) {
    ShowWindow(GetHandle(), SW_HIDE);
    shown_ = false;
    closing_finished_ = true;
    if (closed_) closed_(Generation());
  }
}

void GlobalSendReceiveDock::OnDestroy() {
  KillTimer(GetHandle(), kAnimation);
  KillTimer(GetHandle(), kMovePointer);
  moving_ = false;
  if (GetCapture() == GetHandle()) ReleaseCapture();
  DetachGlobalSendTouchDragWindow(GetHandle());
  for (const HWND target : drop_windows_) RevokeDragDrop(target);
  drop_windows_.clear();
  if (drop_target_) { drop_target_->Release(); drop_target_ = nullptr; }
  channel_.reset();
  system_channel_.reset();
  controller_.reset();
  shown_ = false;
}

LRESULT GlobalSendReceiveDock::MessageHandler(HWND hwnd, UINT message,
    WPARAM wp, LPARAM lp) noexcept {
  if (message == WM_NCCALCSIZE && wp) return 0;
  if (message == WM_ERASEBKGND) return 1;
  if (message == kFrameReady) {
    if (wp == frame_token_ && !shown_ && !closing_ && !closing_finished_) {
      shown_ = true;
      Animate(false);
      if (first_frame_) first_frame_();
    }
    return 0;
  }
  if (message == WM_TIMER && wp == kAnimation) { Tick(); return 0; }
  if (message == WM_TIMER && wp == kMovePointer) { TickMove(); return 0; }
  if (moving_ && (message == WM_MOUSEMOVE || message == WM_LBUTTONUP)) { TickMove(); return 0; }
  if (moving_ && message == WM_CAPTURECHANGED) { EndMove(); return 0; }
  if (message == kDragFinished) {
    if (wp == instance_token_) {
      dragging_ = false;
      if (closing_finished_ && closed_) closed_(Generation());
    }
    return 0;
  }
  if (message == WM_DPICHANGED) {
    const auto result = Win32Window::MessageHandler(hwnd, message, wp, lp);
    GetWindowRect(hwnd, &resting_);
    return result;
  }
  if (message == WM_CLOSE) {
    flutter::EncodableList ids;
    const auto found = payload_.find(Value("items"));
    if (found != payload_.end()) {
      if (const auto* items = std::get_if<flutter::EncodableList>(&found->second)) {
        for (const auto& item : *items) {
          if (const auto* map = std::get_if<Map>(&item)) {
            const auto id = map->find(Value("id"));
            if (id != map->end()) ids.push_back(id->second);
          }
        }
      }
    }
    if (action_) action_(Map{{Value("action"), Value("close")},
      {Value("serial"), Value(Number(payload_, "serial"))},
      {Value("itemIds"), Value(ids)},
      {Value("arrivalGeneration"), Value(Generation())}});
    return 0;
  }
  if (message == WM_ACTIVATE && LOWORD(wp) == WA_INACTIVE) return 0;
  if (controller_) {
    const auto result = controller_->HandleTopLevelWindowProc(hwnd, message, wp, lp);
    if (result) return *result;
  }
  return Win32Window::MessageHandler(hwnd, message, wp, lp);
}
