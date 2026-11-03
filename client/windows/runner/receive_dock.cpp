#include "receive_dock.h"
#include "touch_drag.h"
#include "drop_target.h"
#include "remote_reference_codec.h"
#include "shell_file.h"
#include "utils.h"
#include <flutter/standard_method_codec.h>
#include <flutter_windows.h>
#include <dwmapi.h>
#include <commctrl.h>
#include <algorithm>
#include <cmath>
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
  if (const auto* value = std::get_if<double>(&found->second)) return std::lround(*value);
  return 0;
}
}

GlobalSendReceiveDock::GlobalSendReceiveDock(Map payload, Action action,
    Drag drag, std::function<void()> shown, std::function<void(int64_t)> closed,
    std::function<void(bool)> interaction)
    : payload_(std::move(payload)), action_(std::move(action)), drag_(std::move(drag)),
      first_frame_(std::move(shown)), closed_(std::move(closed)),
      interaction_changed_(std::move(interaction)), interaction_([this] { NotifyInteraction(); }),
      frame_token_(++next_frame_token), instance_token_(frame_token_) { RetainClipboardSlot(); }

std::string GlobalSendReceiveDock::ClipboardSlotPath() const {
  const auto found = payload_.find(Value("clipboardSlot"));
  const auto* slot = found == payload_.end() ? nullptr : std::get_if<Map>(&found->second);
  if (!slot) return {};
  const auto entry = slot->find(Value("localPath"));
  const auto* path = entry == slot->end() ? nullptr : std::get_if<std::string>(&entry->second);
  return path ? *path : std::string();
}
void GlobalSendReceiveDock::RetainClipboardSlot() {
  const auto path = ClipboardSlotPath();
  if (!path.empty() && clipboard_slot_paths_.insert(path).second && action_)
    action_(Map{{Value("action"),Value("clipboardSlotLease")},{Value("paths"),Value(flutter::EncodableList{Value(path)})},{Value("active"),Value(true)}});
}
void GlobalSendReceiveDock::ReleaseClipboardSlotsExcept(const std::string& path) {
  for (auto it = clipboard_slot_paths_.begin(); it != clipboard_slot_paths_.end();) {
    if (*it == path) { ++it; continue; }
    if (action_) action_(Map{{Value("action"),Value("clipboardSlotLease")},{Value("paths"),Value(flutter::EncodableList{Value(*it)})},{Value("active"),Value(false)}});
    it = clipboard_slot_paths_.erase(it);
  }
}

void GlobalSendReceiveDock::NotifyInteraction() {
  const bool active = Interacting();
  if (active == interaction_published_) return;
  interaction_published_ = active;
  if (interaction_changed_) interaction_changed_(active);
}

LRESULT CALLBACK GlobalSendReceiveDock::InteractionObserver(HWND window, UINT message,
    WPARAM wp, LPARAM lp, UINT_PTR, DWORD_PTR data) {
  reinterpret_cast<GlobalSendReceiveDock*>(data)->interaction_.Observe(window, message, wp);
  return DefSubclassProc(window, message, wp, lp);
}

GlobalSendReceiveDock::~GlobalSendReceiveDock() { Destroy(); ReleaseClipboardSlotsExcept({}); }

int64_t GlobalSendReceiveDock::Generation() const { return Number(payload_, "arrivalGeneration"); }

bool GlobalSendReceiveDock::Open() {
  return Create(L"GlobalSend 接收坞", Point(0, 0), Size(480, 184),
      WS_POPUP | WS_CLIPCHILDREN, WS_EX_TOOLWINDOW | WS_EX_TOPMOST);
}

void GlobalSendReceiveDock::Position() {
  const auto entries = payload_.find(Value("items"));
  const auto references = payload_.find(Value("copiedFiles"));
  const auto count = (entries != payload_.end() && std::get_if<flutter::EncodableList>(&entries->second)
      ? std::get<flutter::EncodableList>(entries->second).size() : 0) +
      (references != payload_.end() && std::get_if<flutter::EncodableList>(&references->second)
      ? std::get<flutter::EncodableList>(references->second).size() : 0);
  const bool multiple = count > 1;
  MONITORINFO monitor{sizeof(monitor)};
  const auto target = MonitorFromWindow(GetForegroundWindow(), MONITOR_DEFAULTTOPRIMARY);
  if (!GetMonitorInfoW(target, &monitor)) return;
  const auto bounds = GlobalSendReceiveDockBounds(monitor.rcWork, FlutterDesktopGetDpiForMonitor(target), multiple);
  resting_ = bounds;
  SetWindowPos(GetHandle(), HWND_TOPMOST, bounds.left, bounds.top,
      bounds.right - bounds.left, bounds.bottom - bounds.top, SWP_NOACTIVATE);
}

void GlobalSendReceiveDock::ReflowDisplay(const RECT* suggested) {
  if (moving_) EndMove();
  RECT origin = suggested ? *suggested : resting_;
  const auto target = MonitorFromRect(&origin, MONITOR_DEFAULTTONEAREST);
  MONITORINFO monitor{sizeof(monitor)};
  if (!GetMonitorInfoW(target, &monitor)) return;
  const auto size = GlobalSendReceiveDockBounds(monitor.rcWork, FlutterDesktopGetDpiForMonitor(target), false);
  origin.right = origin.left + size.right - size.left;
  origin.bottom = origin.top + size.bottom - size.top;
  resting_ = GlobalSendReceiveDockFitBounds(origin, monitor.rcWork);
  // An animation's old monitor coordinates are invalid after a display change.
  // Finish that transition without showing a hidden dock or replaying arrival.
  KillTimer(GetHandle(), kAnimation);
  animating_ = false;
  SetWindowPos(GetHandle(), nullptr, resting_.left, resting_.top,
      resting_.right - resting_.left, resting_.bottom - resting_.top,
      SWP_NOZORDER | SWP_NOACTIVATE);
  if (closing_ && shown_) {
    ShowWindow(GetHandle(), SW_HIDE);
    shown_ = false;
    closing_finished_ = true;
    if (closed_) closed_(Generation());
  }
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
    if (call.method_name() == "queueDropBounds") {
      if (call.arguments()) if (const auto* args = std::get_if<Map>(call.arguments())) SetDropRegions(*args);
      result->Success(); return;
    }
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
    if (call.method_name() == "clipboardSlotRendered") {
      const auto* args = call.arguments() ? std::get_if<Map>(call.arguments()) : nullptr;
      std::string path;
      if (args) { const auto found = args->find(Value("path")); if (found != args->end()) if (const auto* value = std::get_if<std::string>(&found->second)) path = *value; }
      if (path == ClipboardSlotPath()) ReleaseClipboardSlotsExcept(path);
      result->Success(); return;
    }
    if (call.method_name() == "ready") { ready_ = true; result->Success(Value(payload_)); return; }
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
    if (call.method_name() == "interaction") {
      const auto* args = call.arguments() ? std::get_if<Map>(call.arguments()) : nullptr;
      const auto active = args ? args->find(Value("active")) : Map::const_iterator{};
      const bool busy = args && active != args->end() && std::get_if<bool>(&active->second) && std::get<bool>(active->second);
      interaction_.Set(GlobalSendUpdateInteraction::flutter_operation, busy);
      result->Success(); return;
    }
    if (call.method_name() == "dragOut" || call.method_name() == "startRemoteReferenceDrag") {
      const auto* arguments = call.arguments() ? std::get_if<Map>(call.arguments()) : nullptr;
      if (!arguments || !drag_) { result->Error("BAD_ARGUMENT", "Expected drag data"); return; }
      dragging_ = true;
      NotifyInteraction();
      const HWND handle = GetHandle();
      const auto instance = instance_token_;
      auto reply = std::make_unique<GlobalSendDockDragReply>(std::move(result), [handle, instance] {
        PostMessageW(handle, kDragFinished, instance, 0);
      });
      const auto session = Number(*arguments, "dragSessionId");
      drag_(*arguments, std::move(reply), handle, [this, session] {
        // The dock has its own Flutter messenger. Main-window notifications
        // cannot retire this isolate's source avatar (session IDs can overlap).
        if (session && system_channel_) system_channel_->InvokeMethod("outgoingDragStarted",
            std::make_unique<Value>(Map{{Value("dragSessionId"), Value(session)}}));
      });
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
  SetWindowSubclass(view, InteractionObserver, 0x4753494e, reinterpret_cast<DWORD_PTR>(this));
  SetChildContent(view, false);
  AttachGlobalSendTouchDragWindow(view, window);
  drop_target_ = CreateGlobalSendDropTarget({{}, [this](GlobalSendDroppedContent content) {
      const auto target = DropDeviceAt(content.screen_point);
      if (target.empty()) return;
      flutter::EncodableList paths, texts;
      for (const auto& path : content.paths) paths.emplace_back(Utf8FromUtf16(path.c_str()));
      if (!content.text.empty()) texts.emplace_back(Utf8FromUtf16(content.text.c_str()));
      Map action{{Value("action"),Value("dropToDevice")}, {Value("targetDeviceId"),Value(target)},
        {Value("serverKey"),Value(drop_server_key_)}, {Value("paths"),Value(paths)}, {Value("texts"),Value(texts)},
        {Value("dropId"),Value("receiver-"+std::to_string(GetTickCount64()))}};
      if (!content.error.empty()) action[Value("error")] = Value(content.error);
      if (const auto reference = DecodeGlobalSendRemoteReference(content.remote_reference))
        action[Value("remoteReference")] = Value(*reference);
      if (action_) action_(action);
    }, [] { return true; }, [this](POINTL point) { return !DropDeviceAt(point).empty(); }, {}, {},
    [this](bool active, POINTL point) { TrackDrop(active, point); }}, window);
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
    animating_ = false;
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
  RetainClipboardSlot();
  if (channel_) channel_->InvokeMethod("content", std::make_unique<Value>(payload_));
}

void GlobalSendReceiveDock::HideAnimated() {
  if (!GetHandle() || closing_) return;
  TrackDrop(false, {});
  if (moving_) EndMove();
  if (shown_) Animate(true);
  else {
    closing_finished_ = true;
    if (closed_) closed_(Generation());
  }
}

void GlobalSendReceiveDock::SetDropRegions(const Map& regions) {
  drop_devices_.clear();
  if (!hovering_drop_) return;
  const auto server = regions.find(Value("serverKey"));
  const auto* key = server == regions.end() ? nullptr : std::get_if<std::string>(&server->second);
  drop_server_key_ = key ? *key : "";
  drop_surface_ = {static_cast<LONG>(Number(regions,"surfaceWidth")), static_cast<LONG>(Number(regions,"surfaceHeight"))};
  const auto found = regions.find(Value("devices"));
  if (found != regions.end()) if (const auto* devices = std::get_if<flutter::EncodableList>(&found->second)) {
    for (const auto& value : *devices) if (const auto* device = std::get_if<Map>(&value)) {
      const auto id = device->find(Value("deviceId"));
      if (id != device->end()) if (const auto* name = std::get_if<std::string>(&id->second))
        drop_devices_.emplace_back(*name, RECT{static_cast<LONG>(Number(*device,"left")),static_cast<LONG>(Number(*device,"top")),
          static_cast<LONG>(Number(*device,"right")),static_cast<LONG>(Number(*device,"bottom"))});
    }
  }
  if (hovering_drop_) TrackDrop(true, drop_pointer_);
}

std::string GlobalSendReceiveDock::DropDeviceAt(POINTL screen) const {
  if (!hovering_drop_ || !controller_ || closing_) return {};
  const HWND view = controller_->view()->GetNativeWindow();
  POINT point{screen.x,screen.y}; RECT bounds{};
  if (!ScreenToClient(view,&point) || !GetClientRect(view,&bounds) ||
      bounds.right != drop_surface_.cx || bounds.bottom != drop_surface_.cy) return {};
  for (const auto& device : drop_devices_) if (PtInRect(&device.second,point)) return device.first;
  return {};
}

void GlobalSendReceiveDock::TrackDrop(bool active, POINTL screen) {
  const bool changed = hovering_drop_ != active;
  hovering_drop_ = active; drop_pointer_ = screen;
  NotifyInteraction();
  if (!active) drop_devices_.clear();
  if (!channel_ || !controller_ || (!active && !changed)) return;
  POINT point{screen.x,screen.y};
  ScreenToClient(controller_->view()->GetNativeWindow(),&point);
  channel_->InvokeMethod("dropHover",std::make_unique<Value>(Map{
    {Value("active"),Value(active)}, {Value("x"),Value(static_cast<int>(point.x))}, {Value("y"),Value(static_cast<int>(point.y))},
    {Value("targetDeviceId"),Value(active ? DropDeviceAt(screen) : "")}}));
}

void GlobalSendReceiveDock::ClearContent() {
  if (!closing_finished_ || Interacting()) return;
  // Keep the display-only engine warm, but release the old card/image tree.
  // The next real arrival must still pass the content-bearing frame gate.
  payload_[Value("items")] = Value(flutter::EncodableList{});
  payload_.erase(Value("reveal"));
  if (channel_) channel_->InvokeMethod("content", std::make_unique<Value>(payload_));
}

void GlobalSendReceiveDock::BeginMove(const Map& args) {
  if (closing_ || dragging_ || moving_) return;
  KillTimer(GetHandle(), kAnimation);
  animating_ = false;
  GetWindowRect(GetHandle(), &move_start_);
  move_anchor_ = {move_start_.left + static_cast<LONG>(Number(args, "x")),
      move_start_.top + static_cast<LONG>(Number(args, "y"))};
  const auto touch = args.find(Value("touch"));
  moving_touch_ = touch != args.end() && std::get_if<bool>(&touch->second) && std::get<bool>(touch->second);
  moving_ = true;
  NotifyInteraction();
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
  NotifyInteraction();
  KillTimer(GetHandle(), kMovePointer);
  if (GetCapture() == GetHandle()) ReleaseCapture();
  GetWindowRect(GetHandle(), &resting_);
  if (channel_) channel_->InvokeMethod("interactionEnded", nullptr);
  if (closing_finished_ && closed_) closed_(Generation());
}

void GlobalSendReceiveDock::Animate(bool closing) {
  animating_ = true;
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
  if (!animating_) return;
  const double t = std::min(1.0, (GetTickCount64() - animation_start_) / (closing_ ? 230.0 : 300.0));
  const double eased = closing_ ? t * t * t : 1 - (1 - t) * (1 - t) * (1 - t);
  const int x = animation_from_ + static_cast<int>((animation_to_ - animation_from_) * eased);
  SetWindowPos(GetHandle(), nullptr, x, resting_.top, 0, 0,
      SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE);
  if (t < 1) return;
  KillTimer(GetHandle(), kAnimation);
  animating_ = false;
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
  if (controller_) RemoveWindowSubclass(controller_->view()->GetNativeWindow(), InteractionObserver, 0x4753494e);
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
  interaction_.Observe(hwnd, message, wp);
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
      interaction_.ReleasePointers();
      NotifyInteraction();
      if (closing_finished_ && closed_) closed_(Generation());
    }
    return 0;
  }
  if (message == WM_DPICHANGED) {
    ReflowDisplay(reinterpret_cast<const RECT*>(lp));
    return 0;
  }
  if (message == WM_DISPLAYCHANGE ||
      (message == WM_SETTINGCHANGE && wp == SPI_SETWORKAREA)) {
    ReflowDisplay();
    return 0;
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
