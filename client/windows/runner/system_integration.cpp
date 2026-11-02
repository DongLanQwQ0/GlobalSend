#include "system_integration.h"
#include "utils.h"
#include "drop_target.h"
#include "touch_drag.h"
#include "clipboard_content.h"
#include "clipboard_image.h"
#include "shell_file.h"
#include "window_lifecycle.h"
#include "autostart.h"
#include "auto_update.h"
#include "update_interaction.h"
#include <system_error>
#include "single_instance.h"
#include "drag_preview.h"
#include "receive_dock.h"
#include "queue_drop_region.h"
#include "local_ip_interfaces.h"
#include <winrt/Windows.Foundation.h>
#include <flutter/method_channel.h>
#include <flutter/method_result_functions.h>
#include <flutter/standard_method_codec.h>
#include <roapi.h>
#include <ole2.h>
#include <shellapi.h>
#include <shlobj.h>
#include <commctrl.h>
#include <cstring>
#include <algorithm>
#include <memory>
#include <string>
#include <vector>
#include <map>
#include <cmath>

namespace {
using Value = flutter::EncodableValue;
using Map = flutter::EncodableMap;
std::unique_ptr<flutter::MethodChannel<Value>> channel;
std::unique_ptr<GlobalSendWindowLifecycle> window_lifecycle;
HWND owner = nullptr;
bool watching = false;
bool ole_initialized = false;
UINT origin_format = 0;
IDropTarget* drop_target = nullptr;
std::vector<HWND> drop_windows;
bool outgoing_drag = false;
HWND outgoing_source_window = nullptr;
HWND import_view = nullptr;
bool native_paste_key_down = false;
void UpdateInteractionChanged();
GlobalSendUpdateInteraction update_interaction(UpdateInteractionChanged);
GlobalSendUpdateExitGate update_exit;
bool update_interaction_published = false, last_update_interaction = false;
constexpr UINT_PTR kPasteSubclass = 0x47535041;

bool HandleNativePaste(UINT message, WPARAM key) {
  if (!channel) return false;
  const bool control_v = message == WM_KEYDOWN && key == 'V' &&
      (GetKeyState(VK_CONTROL) & 0x8000) && !(GetKeyState(VK_MENU) & 0x8000) &&
      !(GetKeyState(VK_SHIFT) & 0x8000) && !(GetKeyState(VK_LWIN) & 0x8000) &&
      !(GetKeyState(VK_RWIN) & 0x8000);
  if (message == WM_PASTE || control_v) {
    if (control_v) native_paste_key_down = true;
    channel->InvokeMethod("pasteRequested", std::make_unique<Value>());
    return true;
  }
  if (message == WM_KEYUP && key == 'V' && native_paste_key_down) {
    native_paste_key_down = false;
    return true;
  }
  if (message == WM_CHAR && key == 0x16) return true;
  if (message == WM_KILLFOCUS) native_paste_key_down = false;
  return false;
}

LRESULT CALLBACK PasteSubclass(HWND window, UINT message, WPARAM key, LPARAM data,
    UINT_PTR, DWORD_PTR) {
  update_interaction.Observe(window, message, key);
  if (HandleNativePaste(message, key)) return 0;
  return DefSubclassProc(window, message, key, data);
}
GlobalSendQueueDropRegion queue_drop;
std::vector<std::pair<std::string, RECT>> device_drop_regions;
std::string drop_server_key;
std::string DeviceDropAt(POINTL screen);
uint64_t drop_sequence = 0;
uint64_t system_generation = 0;
uint64_t clipboard_write_generation = 0;
std::shared_ptr<GlobalSendUpdateLaunch> update_launch;
bool update_starting = false;
bool update_explicit = false;
uint64_t update_request = 0;
constexpr UINT kDestroyReceiveDock = WM_APP + 119;
constexpr UINT kCompleteUpdateExit = WM_APP + 120;
constexpr UINT kResumeUpdateExit = WM_APP + 121;
std::unique_ptr<GlobalSendReceiveDock> receive_dock;
bool UpdateInteracting() {
  return update_interaction.Busy() || outgoing_drag || (receive_dock && receive_dock->Interacting());
}
void UpdateInteractionChanged() {
  const bool busy = UpdateInteracting();
  if (busy && (!update_interaction_published || !last_update_interaction)) update_exit.InteractionBegan();
  if (channel && (!update_interaction_published || last_update_interaction != busy)) {
    update_interaction_published = true; last_update_interaction = busy;
    channel->InvokeMethod("updateInteraction", std::make_unique<Value>(Map{{Value("active"), Value(busy)}}));
  }
  if (!busy && update_exit.Requested() && update_launch && owner)
    PostMessageW(owner, kResumeUpdateExit, 0, 0);
}
void CancelUpdateAttempt(bool notify) {
  update_exit.Cancel();
  ++update_request;
  if (update_launch) update_launch->Cancel();
  update_launch.reset();
  update_starting = false;
  if (notify && channel) channel->InvokeMethod("updateInstallDeferred", std::make_unique<Value>());
}
int64_t receive_serial = -1;
int64_t copied_reference_revision = -1;
struct DockReply {
  int64_t generation;
  std::unique_ptr<flutter::MethodResult<Value>> result;
};
std::vector<DockReply> dock_replies;

int64_t Integer(const Map& map, const char* key) {
  const auto found = map.find(Value(key));
  if (found == map.end()) return 0;
  if (const auto* value = std::get_if<int64_t>(&found->second)) return *value;
  if (const auto* value = std::get_if<int>(&found->second)) return *value;
  return 0;
}
Map DockState(const char* presentation, int64_t generation, bool shown) {
  return Map{{Value("presentation"), Value(presentation)},
    {Value("arrivalGeneration"), Value(generation)}, {Value("shown"), Value(shown)}};
}
void CompleteDockReplies() {
  auto replies = std::move(dock_replies);
  dock_replies.clear();
  for (auto& reply : replies) {
    const bool shown = receive_dock && receive_dock->Shown() &&
        receive_dock->Generation() == reply.generation;
    reply.result->Success(Value(DockState(shown ? "dock" : "superseded", reply.generation, shown)));
  }
}
void CloseDockLater(int64_t expected) {
  if (!receive_dock || receive_dock->Generation() != expected) return;
  CompleteDockReplies();
  PostMessageW(owner, kDestroyReceiveDock, static_cast<WPARAM>(expected), 0);
}

void PublishDragEvent(bool active, const std::string& target) {
  if (!channel) return;
  static bool published = false, last_active = false, last_local = false;
  static std::string last_target;
  if (published && active == last_active && outgoing_drag == last_local && target == last_target) return;
  published = true; last_active = active; last_local = outgoing_drag; last_target = target;
  Map event{{Value("active"), Value(active)}, {Value("importing"), Value(false)},
    {Value("local"), Value(outgoing_drag)}, {Value("targetDeviceId"), Value(target)}};
  channel->InvokeMethod("nativeDrag", std::make_unique<Value>(event));
}
void PublishDrag(bool active) { PublishDragEvent(active, ""); }
void PublishDragAt(bool active, POINTL point) {
  PublishDragEvent(active, active ? DeviceDropAt(point) : std::string());
}

void PublishDrop(GlobalSendDroppedContent content) {
  if (!channel) return;
  flutter::EncodableList paths, texts;
  for (const auto& path : content.paths) paths.emplace_back(Utf8FromUtf16(path.c_str()));
  if (!content.text.empty()) texts.emplace_back(Utf8FromUtf16(content.text.c_str()));
  const std::string id = "windows-" + std::to_string(GetCurrentProcessId()) + "-" +
      std::to_string(GetTickCount64()) + "-" + std::to_string(++drop_sequence);
  Map event{{Value("dropId"), Value(id)}, {Value("paths"), Value(paths)}, {Value("texts"), Value(texts)}};
  const auto target = content.has_screen_point ? DeviceDropAt(content.screen_point) : std::string();
  if (!target.empty()) {
    event.emplace(Value("targetDeviceId"), Value(target));
    event.emplace(Value("serverKey"), Value(drop_server_key));
  }
  if (!content.error.empty()) event.emplace(Value("error"), Value(content.error));
  channel->InvokeMethod("nativeDrop", std::make_unique<Value>(event));
}

std::wstring Wide(const std::string& text) {
  if (text.empty()) return {};
  int size = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, text.data(), static_cast<int>(text.size()), nullptr, 0);
  std::wstring value(size > 0 ? size : 0, L'\0');
  if (size > 0) MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, text.data(), static_cast<int>(text.size()), value.data(), size);
  return value;
}
std::string String(const Map& map, const char* key) {
  const auto found = map.find(Value(key));
  if (found == map.end()) return {};
  const auto* value = std::get_if<std::string>(&found->second);
  return value ? *value : std::string();
}
bool Bool(const Map& map, const char* key) {
  const auto found = map.find(Value(key));
  return found != map.end() && std::get_if<bool>(&found->second) && std::get<bool>(found->second);
}
double Number(const Map& map, const char* key) {
  const auto found = map.find(Value(key));
  if (found == map.end()) return 0;
  if (const auto* value = std::get_if<double>(&found->second)) return *value;
  return static_cast<double>(Integer(map, key));
}
std::string DeviceDropAt(POINTL screen) {
  if (!import_view || !queue_drop.enabled || !IsWindowVisible(import_view)) return {};
  POINT point{screen.x, screen.y}; RECT client{};
  if (!ScreenToClient(import_view, &point) || !GetClientRect(import_view, &client) ||
      client.right != queue_drop.surface.cx || client.bottom != queue_drop.surface.cy) return {};
  for (const auto& region : device_drop_regions) if (PtInRect(&region.second, point)) return region.first;
  return {};
}
bool LocalDropAt(POINTL screen) {
  if (!import_view || !IsWindowVisible(import_view)) return false;
  POINT point{screen.x, screen.y};
  RECT client{};
  if (!ScreenToClient(import_view, &point) || !GetClientRect(import_view, &client)) return false;
  return queue_drop.Contains(point, SIZE{client.right, client.bottom}) || !DeviceDropAt(screen).empty();
}
bool ExcludedDropAt(POINTL screen) {
  if (!import_view || !IsWindowVisible(import_view)) return false;
  POINT point{screen.x, screen.y}; RECT client{};
  if (!ScreenToClient(import_view, &point) || !GetClientRect(import_view, &client)) return false;
  return queue_drop.Excludes(point, SIZE{client.right, client.bottom});
}
bool ClipboardBytes(UINT format, const void* bytes, size_t count) {
  HGLOBAL memory = GlobalAlloc(GMEM_MOVEABLE, count);
  if (!memory) return false;
  auto* destination = GlobalLock(memory);
  if (!destination) { GlobalFree(memory); return false; }
  memcpy(destination, bytes, count); GlobalUnlock(memory);
  if (!SetClipboardData(format, memory)) { GlobalFree(memory); return false; }
  return true;
}
std::wstring ReadClipboardText(UINT format, size_t maximum) {
  HANDLE memory = GetClipboardData(format);
  if (!memory) return {};
  SIZE_T size = GlobalSize(memory);
  if (size < sizeof(wchar_t) || size > maximum * sizeof(wchar_t)) return {};
  const auto* text = static_cast<const wchar_t*>(GlobalLock(memory));
  if (!text) return {};
  std::wstring value(text, wcsnlen(text, size / sizeof(wchar_t)));
  GlobalUnlock(memory); return value;
}
bool ClipboardPrivate() {
  bool private_content = IsClipboardFormatAvailable(RegisterClipboardFormatW(L"ExcludeClipboardContentFromMonitorProcessing"));
  for (const auto* name : {L"CanIncludeInClipboardHistory", L"CanUploadToCloudClipboard"}) {
    HANDLE memory = GetClipboardData(RegisterClipboardFormatW(name));
    if (memory && GlobalSize(memory) >= sizeof(DWORD)) {
      const auto* value = static_cast<const DWORD*>(GlobalLock(memory));
      if (value) { private_content = private_content || *value == 0; GlobalUnlock(memory); }
    }
  }
  return private_content;
}

winrt::fire_and_forget ReadClipboard(std::wstring path, DWORD expected_sequence,
    bool image_only, std::shared_ptr<flutter::MethodResult<Value>> result) {
  const winrt::apartment_context platform_thread;
  const auto generation = system_generation;
  const auto window = owner;
  co_await winrt::resume_background();
  const auto content = ReadGlobalSendClipboard(window, path, expected_sequence, image_only);
  co_await platform_thread;
  if (!channel || generation != system_generation) {
    for (const auto& generated : content.temporary_paths) DeleteFileW(generated.c_str());
    co_return;
  }
  if (!content.error.empty()) { result->Error("CLIPBOARD_READ", content.error); co_return; }
  flutter::EncodableList paths, texts, temporary;
  for (const auto& value : content.paths) paths.emplace_back(Utf8FromUtf16(value.c_str()));
  for (const auto& value : content.texts) texts.emplace_back(Utf8FromUtf16(value.c_str()));
  for (const auto& value : content.temporary_paths) temporary.emplace_back(Utf8FromUtf16(value.c_str()));
  result->Success(Value(Map{{Value("paths"), Value(paths)}, {Value("texts"), Value(texts)},
      {Value("temporaryPaths"), Value(temporary)}, {Value("changed"), Value(content.changed)}}));
}

winrt::fire_and_forget WriteClipboardImage(std::wstring path, std::wstring marker,
    std::shared_ptr<flutter::MethodResult<Value>> result) {
  const winrt::apartment_context platform_thread;
  const auto generation = system_generation;
  const auto revision = ++clipboard_write_generation;
  const auto sequence = GetClipboardSequenceNumber();
  co_await winrt::resume_background();
  const HRESULT initialized = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
  GlobalSendClipboardImage image;
  if (SUCCEEDED(initialized) || initialized == RPC_E_CHANGED_MODE)
    image = PrepareGlobalSendClipboardImage(path);
  else image.status = initialized;
  if (SUCCEEDED(initialized)) CoUninitialize();
  co_await platform_thread;
  if (!channel || generation != system_generation) co_return;
  // A newer remote write or a local copy wins while this image is decoding.
  if (revision != clipboard_write_generation || sequence != GetClipboardSequenceNumber()) {
    result->Success(Value(false)); co_return;
  }
  if (FAILED(image.status)) { result->Error("CLIPBOARD_IMAGE", "无法读取同步图片"); co_return; }
  if (!OpenClipboard(owner)) { result->Error("CLIPBOARD_BUSY", "剪贴板正被占用"); co_return; }
  bool ok = EmptyClipboard() && ClipboardBytes(origin_format, marker.c_str(), (marker.size() + 1) * sizeof(wchar_t));
  DWORD zero = 0;
  ok = ClipboardBytes(RegisterClipboardFormatW(L"CanIncludeInClipboardHistory"), &zero, sizeof(zero)) && ok;
  ok = ClipboardBytes(RegisterClipboardFormatW(L"CanUploadToCloudClipboard"), &zero, sizeof(zero)) && ok;
  if (ok) ok = ClipboardBytes(RegisterClipboardFormatW(L"PNG"), image.png.data(), image.png.size());
  if (ok) ok = ClipboardBytes(CF_DIBV5, image.dib_v5.data(), image.dib_v5.size());
  if (ok) ok = ClipboardBytes(CF_DIB, image.dib.data(), image.dib.size());
  if (!ok) EmptyClipboard();
  CloseClipboard();
  if (ok) result->Success(Value(true)); else result->Error("CLIPBOARD_WRITE", "无法写入同步图片");
}

winrt::fire_and_forget RevealFile(std::wstring path,
    std::shared_ptr<flutter::MethodResult<Value>> result) {
  const winrt::apartment_context platform_thread;
  const auto generation = system_generation;
  co_await winrt::resume_background();
  const HRESULT initialized = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
  const HRESULT status = SUCCEEDED(initialized) || initialized == RPC_E_CHANGED_MODE
      ? RevealGlobalSendFile(path) : initialized;
  if (SUCCEEDED(initialized)) CoUninitialize();
  co_await platform_thread;
  if (!channel || generation != system_generation) co_return;
  if (SUCCEEDED(status)) {
    result->Success();
  } else {
    const auto message = status == HRESULT_FROM_WIN32(ERROR_FILE_NOT_FOUND) ||
        status == HRESULT_FROM_WIN32(ERROR_PATH_NOT_FOUND)
        ? "文件已不存在" : status == E_ACCESSDENIED
        ? "无法访问文件位置" : "无法在资源管理器定位文件";
    result->Error("REVEAL_FILE", message, Value(static_cast<int64_t>(status)));
  }
}

// Browser startup (COM/DDE) can wait on another process. Keep that wait off the
// platform/UI thread, including when an explicit remote intent arrives in tray.
winrt::fire_and_forget OpenWebUrl(std::string url, HWND parent,
    std::shared_ptr<flutter::MethodResult<Value>> result) {
  const winrt::apartment_context platform_thread;
  const auto generation = system_generation;
  co_await winrt::resume_background();
  const HRESULT initialized = CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
  const HRESULT status = SUCCEEDED(initialized) || initialized == RPC_E_CHANGED_MODE
      ? OpenGlobalSendWebUrl(parent, url) : initialized;
  if (SUCCEEDED(initialized)) CoUninitialize();
  co_await platform_thread;
  if (!channel || generation != system_generation) co_return;
  if (status == E_INVALIDARG) result->Error("INVALID_URL", "网址无效");
  else if (SUCCEEDED(status)) result->Success();
  else result->Error("OPEN_URL_FAILED", "无法打开网址");
}

winrt::fire_and_forget InstallUpdate(std::wstring package, std::string version,
    int64_t build, HWND window, bool background, uint64_t request,
    std::shared_ptr<flutter::MethodResult<Value>> result) {
  const winrt::apartment_context platform_thread;
  const auto generation = system_generation;
  co_await winrt::resume_background();
  const HRESULT runtime = RoInitialize(RO_INIT_MULTITHREADED);
  std::shared_ptr<GlobalSendUpdateLaunch> launch;
  std::string error;
  try {
    if (FAILED(runtime) && runtime != RPC_E_CHANGED_MODE) winrt::check_hresult(runtime);
    launch = GlobalSendUpdateLaunch::Start(package, version, build, window, background, request);
  }
  catch (const winrt::hresult_error& failure) { error = winrt::to_string(failure.message()); }
  catch (const std::exception& failure) { error = failure.what(); }
  if (SUCCEEDED(runtime)) RoUninitialize();
  co_await platform_thread;
  if (!channel || generation != system_generation) {
    if (launch) launch->Cancel();
    co_return;
  }
  if (request != update_request) {
    if (launch) launch->Cancel();
    result->Success(Value(Map{{Value("state"), Value("cancelled")}}));
    co_return;
  }
  update_starting = false;
  if (!error.empty()) { result->Error("UPDATE_INSTALL", "无法启动更新，当前版本未修改", Value(error)); co_return; }
  update_launch = launch;
  result->Success(Value(Map{{Value("state"), Value("started")},
      {Value("resultPath"), Value(Utf8FromUtf16(launch->ResultPath().c_str()))}}));
  launch->Continue();
}

class DragSource final : public IDropSource {
 public:
  explicit DragSource(bool touch = false) : touch_(touch) {}
  HRESULT STDMETHODCALLTYPE QueryInterface(REFIID id, void** object) override {
    if (!object) return E_POINTER;
    if (id == IID_IUnknown || id == IID_IDropSource) { *object = static_cast<IDropSource*>(this); AddRef(); return S_OK; }
    *object = nullptr; return E_NOINTERFACE;
  }
  ULONG STDMETHODCALLTYPE AddRef() override { return ++references_; }
  ULONG STDMETHODCALLTYPE Release() override { auto count = --references_; if (!count) delete this; return count; }
  HRESULT STDMETHODCALLTYPE QueryContinueDrag(BOOL escape, DWORD keys) override {
    if (touch_) return GlobalSendDesktopTouchDragStatus(escape, keys);
    if (escape) return DRAGDROP_S_CANCEL;
    return (keys & MK_LBUTTON) ? S_OK : DRAGDROP_S_DROP;
  }
  HRESULT STDMETHODCALLTYPE GiveFeedback(DWORD) override { return DRAGDROP_S_USEDEFAULTCURSORS; }
 private:
  ULONG references_ = 1;
  bool touch_ = false;
};

void Drag(const Map& arguments, std::unique_ptr<flutter::MethodResult<Value>> result,
    HWND source_window, std::function<void()> started = {}) {
  const auto session = Integer(arguments, "dragSessionId");
  if (!started && session != 0) started = [session] {
    if (channel) channel->InvokeMethod("outgoingDragStarted",
        std::make_unique<Value>(Map{{Value("dragSessionId"), Value(session)}}));
  };
  std::vector<uint8_t> bytes;
  std::vector<std::wstring> export_paths;
  std::wstring export_text;
  CLIPFORMAT format = CF_UNICODETEXT;
  auto paths = arguments.find(Value("paths"));
  if (paths != arguments.end() && std::get_if<flutter::EncodableList>(&paths->second)) {
    std::wstring names;
    const auto& files = std::get<flutter::EncodableList>(paths->second);
    if (files.empty()) { result->Success(Value(false)); return; }
    for (const auto& item : files) {
      const auto* path = std::get_if<std::string>(&item); if (!path) { result->Error("DRAG_PATH", "Invalid file path"); return; }
      auto wide = Wide(*path);
      // CF_HDROP references the source directly. Do not hydrate/stat network
      // paths on Flutter's platform thread before the drop target opens them.
      if (wide.empty()) { result->Error("DRAG_PATH", "Invalid file path"); return; }
      export_paths.push_back(wide);
      names.append(wide); names.push_back(L'\0');
    }
    names.push_back(L'\0');
    DROPFILES header{}; header.pFiles = sizeof(DROPFILES); header.fWide = TRUE;
    bytes.resize(sizeof(header) + names.size() * sizeof(wchar_t));
    memcpy(bytes.data(), &header, sizeof(header)); memcpy(bytes.data() + sizeof(header), names.data(), names.size() * sizeof(wchar_t));
    format = CF_HDROP;
  } else {
    const auto text = Wide(String(arguments, "text"));
    if (text.empty() || text.size() > 100000) { result->Error("DRAG_TEXT", "Empty or oversized text"); return; }
    bytes.resize((text.size() + 1) * sizeof(wchar_t)); memcpy(bytes.data(), text.c_str(), bytes.size());
    export_text = text;
  }
  const auto pointer_kind = String(arguments, "pointerKind");
  HBITMAP ready_preview = nullptr;
  const auto rgba = arguments.find(Value("previewRgba"));
  if (rgba != arguments.end()) {
    if (const auto* pixels = std::get_if<std::vector<uint8_t>>(&rgba->second)) {
      const auto number = [&arguments](const char* key) {
        const auto entry = arguments.find(Value(key));
        if (entry == arguments.end()) return 0;
        if (const auto* value = std::get_if<int32_t>(&entry->second)) return *value;
        return 0;
      };
      ready_preview = GlobalSendDragBitmapFromRgba(*pixels,
          number("previewWidth"), number("previewHeight"));
    }
  }
  IDataObject* payload = nullptr;
  if (FAILED(CreateGlobalSendDragData(format, bytes, &payload))) {
    if (ready_preview) DeleteObject(ready_preview);
    result->Error("DRAG_DATA", "Windows could not prepare drag content");
    return;
  }
  const bool pointer_export = pointer_kind == "touch" || pointer_kind == "stylus" ||
      pointer_kind == "invertedStylus";
  if (pointer_export || (pointer_kind != "mouse" && HasGlobalSendTouchContact())) {
    update_interaction.Set(GlobalSendUpdateInteraction::export_operation, true);
      // A held native primary contact drives this explicit desktop adapter.
      // Do not retry the WinRT CoreWindow path or use the plain mouse path.
      auto data = std::shared_ptr<IDataObject>(payload,
          [](IDataObject* value) { value->Release(); });
      auto source = std::shared_ptr<DragSource>(new DragSource(true),
          [](DragSource* value) { value->Release(); });
    auto completion = std::shared_ptr<flutter::MethodResult<Value>>(std::move(result));
      StartGlobalSendDesktopTouchDrag(std::move(export_text), std::move(export_paths), source_window,
        [data, source, source_window, started](HBITMAP bitmap, DWORD* effect) {
          InitializeGlobalSendDragPreviewFromBitmap(data.get(), source_window, bitmap);
          outgoing_drag = true;
          outgoing_source_window = source_window;
          if (started) started();
          const auto status = DoDragDrop(data.get(), source.get(), DROPEFFECT_COPY, effect);
          PublishDrag(false);
          outgoing_drag = false;
          outgoing_source_window = nullptr;
          return status;
        },
      [completion](bool copied, const std::string& error) {
        outgoing_drag = false;
        outgoing_source_window = nullptr;
        PublishDrag(false);
        if (error.empty()) completion->Success(Value(copied));
        else completion->Error("TOUCH_DRAG_FAILED", error);
        update_interaction.ReleasePointers();
        update_interaction.Set(GlobalSendUpdateInteraction::export_operation, false);
      }, {}, ready_preview);
    return;
  }
  auto* data = payload; auto* source = new DragSource();
  HBITMAP bitmap = ready_preview ? ready_preview : GlobalSendContentDragBitmap(export_text, export_paths);
  InitializeGlobalSendDragPreviewFromBitmap(data, source_window, bitmap);
  if (bitmap) DeleteObject(bitmap);
  DWORD effect = DROPEFFECT_NONE;
  update_interaction.Set(GlobalSendUpdateInteraction::export_operation, true);
  outgoing_drag = true;
  outgoing_source_window = source_window;
  if (started) started();
  HRESULT status = DoDragDrop(data, source, DROPEFFECT_COPY, &effect);
  PublishDrag(false);
  outgoing_drag = false;
  outgoing_source_window = nullptr;
  data->Release(); source->Release();
  if (status == DRAGDROP_S_DROP || status == DRAGDROP_S_CANCEL) result->Success(Value(status == DRAGDROP_S_DROP && effect == DROPEFFECT_COPY));
  else result->Error("DRAG_FAILED", "Windows OLE drag could not start");
  update_interaction.ReleasePointers();
  update_interaction.Set(GlobalSendUpdateInteraction::export_operation, false);
}
bool PrepareReceiveDock(Map payload) {
  if (receive_dock) return true;
  receive_dock = std::make_unique<GlobalSendReceiveDock>(std::move(payload),
    [](const Map& action) {
      if (channel) channel->InvokeMethod("receiveDockAction", std::make_unique<Value>(action));
      if (String(action, "action") == "close") CloseDockLater(Integer(action, "arrivalGeneration"));
    }, [](const Map& values, auto completion, HWND window, std::function<void()> started) {
      Drag(values, std::move(completion), window, std::move(started));
    }, [] { CompleteDockReplies(); }, [](int64_t generation) {
      PostMessageW(owner, kDestroyReceiveDock, static_cast<WPARAM>(generation), 0);
    }, [](bool) { UpdateInteractionChanged(); });
  if (receive_dock->Open()) return true;
  receive_dock.reset();
  return false;
}
}  // namespace

void RegisterGlobalSendSystem(flutter::BinaryMessenger* messenger, HWND window, HWND flutter_view, bool initially_visible) {
  ++system_generation;
  owner = window; ole_initialized = SUCCEEDED(OleInitialize(nullptr));
  import_view = flutter_view;
  queue_drop = {};
  RegisterGlobalSendTouchDrag(flutter_view, window);
  origin_format = RegisterClipboardFormatW(L"GlobalSend.ClipboardOrigin.v1");
  channel = std::make_unique<flutter::MethodChannel<Value>>(messenger, "dev.globalsend/system", &flutter::StandardMethodCodec::GetInstance());
  window_lifecycle = std::make_unique<GlobalSendWindowLifecycle>(window,
      [](bool visible) {
        if (channel) channel->InvokeMethod("windowVisibilityChanged",
            std::make_unique<Value>(Map{{Value("visible"), Value(visible)}}));
      }, [](const GlobalSendWindowState& state) {
        if (!channel) return;
        Map value{{Value("left"), Value(state.left)}, {Value("top"), Value(state.top)},
            {Value("width"), Value(state.width)}, {Value("height"), Value(state.height)},
            {Value("maximized"), Value(state.maximized)}};
        channel->InvokeMethod("windowStateChanged", std::make_unique<Value>(value));
      }, initially_visible);
  SetGlobalSendLaunchConsumer([](std::vector<std::wstring> paths) {
    PublishDrop(GlobalSendDroppedContent{std::move(paths), {}, {}});
  });
  channel->SetMethodCallHandler([](const auto& call, auto result) {
    if (call.method_name() == "autoStartEnabled" || call.method_name() == "setAutoStart") {
      try {
        if (call.method_name() == "setAutoStart") {
          const auto* enabled = call.arguments() ? std::get_if<bool>(call.arguments()) : nullptr;
          if (!enabled) { result->Error("BAD_ARGUMENT", "Expected startup toggle"); return; }
          SetGlobalSendAutoStart(*enabled);
        }
        result->Success(Value(GlobalSendAutoStartEnabled()));
      } catch (const std::system_error& error) {
        result->Error("AUTOSTART", "无法更新开机启动设置", Value(error.code().value()));
      }
      return;
    }
    if (call.method_name() == "localIpInterfaces") {
      try {
        flutter::EncodableList interfaces;
        for (const auto& adapter : ReadGlobalSendIpInterfaces()) {
          flutter::EncodableList addresses;
          for (const auto& ip : adapter.addresses) addresses.emplace_back(ip);
          interfaces.emplace_back(Map{{Value("id"), Value(adapter.id)},
              {Value("name"), Value(adapter.name)},
              {Value("description"), Value(adapter.description)},
              {Value("kind"), Value(adapter.kind)},
              {Value("addresses"), Value(addresses)}});
        }
        result->Success(Value(interfaces));
      } catch (const std::exception& error) {
        result->Error("IP_INTERFACES", error.what());
      }
      return;
    }
    if (call.method_name() == "receivedWindowState") {
      result->Success(Value(Map{{Value("floating"), Value(false)},
          {Value("supported"), Value(true)},
          {Value("dockVisible"), Value(receive_dock && receive_dock->Shown())},
          {Value("arrivalGeneration"), Value(static_cast<int64_t>(window_lifecycle
              ? window_lifecycle->ReceiptArrivalGeneration() : 0))}}));
      return;
    }
    if (call.method_name() == "prepareReceiveDock") {
      // No content, focus activation or visible window during warm-up.
      result->Success(Value(PrepareReceiveDock(Map{
        {Value("items"), Value(flutter::EncodableList{})}
      })));
      return;
    }
    if (call.method_name() == "notifyUpdate") {
      const auto* args = call.arguments() ? std::get_if<Map>(call.arguments()) : nullptr;
      const auto ready = args ? args->find(Value("ready")) : Map::const_iterator{};
      const bool downloaded = args && ready != args->end() && std::get_if<bool>(&ready->second) && std::get<bool>(ready->second);
      result->Success(Value(args && window_lifecycle && window_lifecycle->NotifyReceived(
          downloaded ? L"GlobalSend 更新已下载" : L"GlobalSend 有新版本",
          Wide(String(*args, "version")) + (downloaded ? L" 已就绪，点击打开 GlobalSend" : L" 可更新，点击查看"), true)));
      return;
    }
    const auto* arguments = call.arguments() ? std::get_if<Map>(call.arguments()) : nullptr;
    if (!arguments) { result->Error("BAD_ARGUMENT", "Expected operation map"); return; }
    if (call.method_name() == "mainUpdateInteraction") {
      update_interaction.Set(GlobalSendUpdateInteraction::flutter_operation, Bool(*arguments, "active"));
      result->Success(); return;
    }
    if (call.method_name() == "cancelUpdateInstall") {
      if (!Bool(*arguments, "automaticOnly") || !update_explicit) CancelUpdateAttempt(false);
      result->Success(); return;
    }
    if (call.method_name() == "installUpdate") {
      if (update_launch && !update_launch->Running()) update_launch.reset();
      if (update_starting || update_launch) {
        result->Success(Value(Map{{Value("state"), Value("started")}}));
        return;
      }
      if (UpdateInteracting()) {
        UpdateInteractionChanged();
        result->Success(Value(Map{{Value("state"), Value("interaction-pending")}})); return;
      }
      const auto path = Wide(String(*arguments, "path"));
      const auto version = String(*arguments, "version");
      const auto build = Integer(*arguments, "build");
      const auto requested = arguments->find(Value("explicit"));
      const auto* explicit_value = requested == arguments->end() ? nullptr : std::get_if<bool>(&requested->second);
      const bool explicit_install = explicit_value && *explicit_value;
      if (path.empty() || version.empty() || build <= 0) { result->Error("BAD_ARGUMENT", "Missing update package or version"); return; }
      update_starting = true;
      update_explicit = explicit_install;
      InstallUpdate(path, version, build, owner,
          GlobalSendUpdateBackground(explicit_install, window_lifecycle && window_lifecycle->Visible()),
          ++update_request,
          std::shared_ptr<flutter::MethodResult<Value>>(std::move(result)));
    } else if (call.method_name() == "presentReceiveDock") {
      auto payload = *arguments;
      const auto serial = Integer(payload, "serial");
      const auto reference_revision = Integer(payload, "referenceRevision");
      if (serial != receive_serial || reference_revision != copied_reference_revision) {
        receive_serial = serial;
        copied_reference_revision = reference_revision;
        if (window_lifecycle) window_lifecycle->ShowReceived();
      }
      const auto generation = static_cast<int64_t>(window_lifecycle
          ? window_lifecycle->ReceiptArrivalGeneration() : 0);
      payload[Value("arrivalGeneration")] = Value(generation);
      const auto items = payload.find(Value("items"));
      const auto* entries = items == payload.end() ? nullptr :
          std::get_if<flutter::EncodableList>(&items->second);
      const auto references = payload.find(Value("copiedFiles"));
      const auto* copied = references == payload.end() ? nullptr : std::get_if<flutter::EncodableList>(&references->second);
      if ((!entries || entries->empty()) && (!copied || copied->empty())) {
        if (receive_dock) CloseDockLater(receive_dock->Generation());
        result->Success(Value(DockState("main", generation, false)));
      } else if (window_lifecycle && window_lifecycle->Focused()) {
        if (receive_dock) CloseDockLater(receive_dock->Generation());
        result->Success(Value(DockState("main", generation, true)));
      } else {
        dock_replies.push_back({generation, std::move(result)});
        if (receive_dock) {
          receive_dock->Update(std::move(payload));
          if (receive_dock->Shown()) CompleteDockReplies();
        } else {
          if (!PrepareReceiveDock(std::move(payload))) {
            CompleteDockReplies();
            if (window_lifecycle) window_lifecycle->NotifyReceived(L"GlobalSend", L"收到新内容");
          }
        }
      }
    } else if (call.method_name() == "dismissReceiveDock") {
      CloseDockLater(Integer(*arguments, "arrivalGeneration"));
      result->Success();
    } else if (call.method_name() == "activateWindow") {
      if (receive_dock) CloseDockLater(receive_dock->Generation());
      if (window_lifecycle) window_lifecycle->Activate();
      result->Success();
    } else if (call.method_name() == "drainLaunchFiles") {
      DrainGlobalSendLaunchFiles();
      result->Success();
    } else if (call.method_name() == "windowVisible") {
      result->Success(Value(window_lifecycle && window_lifecycle->Visible()));
    } else if (call.method_name() == "showReceivedWindow") {
      if (window_lifecycle) {
        if (!window_lifecycle->ShowReceived()) {
          window_lifecycle->NotifyReceived(Wide(String(*arguments, "title")), Wide(String(*arguments, "body")));
        }
        channel->InvokeMethod("receiptArrival", std::make_unique<Value>(Map{
            {Value("arrivalGeneration"), Value(static_cast<int64_t>(window_lifecycle->ReceiptArrivalGeneration()))}}));
      }
      result->Success();
    } else if (call.method_name() == "dismissReceivedWindow") {
      std::optional<uint64_t> expected;
      const auto found = arguments->find(Value("arrivalGeneration"));
      if (found != arguments->end()) {
        if (const auto* wide_value = std::get_if<int64_t>(&found->second)) expected = static_cast<uint64_t>(*wide_value);
        else if (const auto* small_value = std::get_if<int>(&found->second)) expected = static_cast<uint64_t>(*small_value);
      }
      if (window_lifecycle) window_lifecycle->DismissReceived(expected);
      if (receive_dock && (!expected || *expected == static_cast<uint64_t>(receive_dock->Generation())))
        CloseDockLater(receive_dock->Generation());
      result->Success();
    } else if (call.method_name() == "restoreWindow") {
      auto integer = [&](const char* key, int fallback) {
        const auto found = arguments->find(Value(key));
        if (found == arguments->end()) return fallback;
        const auto* value = std::get_if<int>(&found->second);
        return value ? *value : fallback;
      };
      if (window_lifecycle) window_lifecycle->Restore({integer("left", 10), integer("top", 10),
          integer("width", 950), integer("height", 650), Bool(*arguments, "maximized")});
      result->Success();
    } else if (call.method_name() == "queueDropBounds") {
      device_drop_regions.clear();
      queue_drop.exclusions.clear();
      const auto exclusions = arguments->find(Value("exclusions"));
      if (exclusions != arguments->end()) if (const auto* values = std::get_if<flutter::EncodableList>(&exclusions->second)) {
        for (const auto& value : *values) if (const auto* region = std::get_if<Map>(&value)) {
          queue_drop.exclusions.push_back(RECT{
            static_cast<LONG>(std::floor(Number(*region, "left"))), static_cast<LONG>(std::floor(Number(*region, "top"))),
            static_cast<LONG>(std::ceil(Number(*region, "right"))), static_cast<LONG>(std::ceil(Number(*region, "bottom")))});
        }
      }
      drop_server_key = String(*arguments, "serverKey");
      const auto devices = arguments->find(Value("devices"));
      if (devices != arguments->end()) if (const auto* values = std::get_if<flutter::EncodableList>(&devices->second)) {
        for (const auto& value : *values) if (const auto* region = std::get_if<Map>(&value)) {
          device_drop_regions.emplace_back(String(*region, "deviceId"), RECT{
            static_cast<LONG>(std::floor(Number(*region, "left"))), static_cast<LONG>(std::floor(Number(*region, "top"))),
            static_cast<LONG>(std::ceil(Number(*region, "right"))), static_cast<LONG>(std::ceil(Number(*region, "bottom")))});
        }
      }
      queue_drop.enabled = Bool(*arguments, "enabled");
      if (queue_drop.enabled) {
        queue_drop.bounds = RECT{
          static_cast<LONG>(std::floor(Number(*arguments, "left"))),
          static_cast<LONG>(std::floor(Number(*arguments, "top"))),
          static_cast<LONG>(std::ceil(Number(*arguments, "right"))),
          static_cast<LONG>(std::ceil(Number(*arguments, "bottom")))};
        queue_drop.surface = SIZE{
          static_cast<LONG>(std::lround(Number(*arguments, "surfaceWidth"))),
          static_cast<LONG>(std::lround(Number(*arguments, "surfaceHeight")))};
      }
      result->Success();
    } else if (call.method_name() == "clipboardWatch") {
      const bool enable = Bool(*arguments, "enabled");
      bool ok = enable ? (watching || AddClipboardFormatListener(owner)) : (!watching || RemoveClipboardFormatListener(owner));
      if (ok) watching = enable;
      if (ok) result->Success(); else result->Error("CLIPBOARD_WATCH", "Clipboard listener unavailable");
    } else if (call.method_name() == "clipboardKind") {
      result->Success(Value(GlobalSendClipboardKind()));
    } else if (call.method_name() == "clipboardSuggestion") {
      result->Success(Value(Map{{Value("available"),Value(true)},
        {Value("revision"),Value(std::to_string(GetClipboardSequenceNumber()))},
        {Value("kind"),Value(GlobalSendClipboardKind())}}));
    } else if (call.method_name() == "clipboardFilePaths") {
      if (!OpenClipboard(owner)) { result->Error("CLIPBOARD_BUSY", "Clipboard is in use"); return; }
      flutter::EncodableList paths;
      if (!ClipboardPrivate() && ReadClipboardText(origin_format, 300).empty())
        for (const auto& path : ReadGlobalSendClipboardPaths()) paths.emplace_back(Utf8FromUtf16(path.c_str()));
      CloseClipboard();
      result->Success(Value(paths));
    } else if (call.method_name() == "readClipboard") {
      ReadClipboard(Wide(String(*arguments, "bitmapPath")),
          static_cast<DWORD>(Integer(*arguments, "expectedSequence")), Bool(*arguments, "imageOnly"),
          std::shared_ptr<flutter::MethodResult<Value>>(std::move(result)));
    } else if (call.method_name() == "writeClipboardImage") {
      WriteClipboardImage(Wide(String(*arguments, "path")),
          Wide(String(*arguments, "originDeviceId") + "\n" + String(*arguments, "sourceEventId")),
          std::shared_ptr<flutter::MethodResult<Value>>(std::move(result)));
    } else if (call.method_name() == "cancelClipboardImage") {
      ++clipboard_write_generation;
      result->Success();
    } else if (call.method_name() == "writeClipboard") {
      ++clipboard_write_generation;
      if (!OpenClipboard(owner)) { result->Error("CLIPBOARD_BUSY", "Clipboard is in use"); return; }
      const auto text = Wide(String(*arguments, "text"));
      const auto marker = Wide(String(*arguments, "originDeviceId") + "\n" + String(*arguments, "sourceEventId"));
      // Publish no plaintext unless its no-sync marker has already been installed.
      bool ok = EmptyClipboard() && ClipboardBytes(origin_format, marker.c_str(), (marker.size() + 1) * sizeof(wchar_t));
      if (Bool(*arguments, "private")) {
        DWORD zero = 0;
        ok = ClipboardBytes(RegisterClipboardFormatW(L"CanIncludeInClipboardHistory"), &zero, sizeof(zero)) && ok;
        ok = ClipboardBytes(RegisterClipboardFormatW(L"CanUploadToCloudClipboard"), &zero, sizeof(zero)) && ok;
      }
      if (ok) ok = ClipboardBytes(CF_UNICODETEXT, text.c_str(), (text.size() + 1) * sizeof(wchar_t));
      if (!ok) EmptyClipboard();
      CloseClipboard();
      if (ok) result->Success(); else result->Error("CLIPBOARD_WRITE", "Clipboard copy was not completed");
    } else if (call.method_name() == "dragOut") {
      if (!ole_initialized) { result->Error("OLE_UNAVAILABLE", "Windows drag is unavailable"); return; }
      Drag(*arguments, std::move(result), owner);
    } else if (call.method_name() == "openWebUrl") {
      OpenWebUrl(String(*arguments, "url"), owner,
          std::shared_ptr<flutter::MethodResult<Value>>(std::move(result)));
    } else if (call.method_name() == "revealFile") {
      RevealFile(Wide(String(*arguments, "path")),
          std::shared_ptr<flutter::MethodResult<Value>>(std::move(result)));
    } else result->NotImplemented();
  });
  if (ole_initialized) {
    drop_target = CreateGlobalSendDropTarget({PublishDrag, PublishDrop,
      [] { return outgoing_drag; }, LocalDropAt, PublishDragAt, ExcludedDropAt,
      [](bool active, POINTL) { update_interaction.Set(GlobalSendUpdateInteraction::drop_hover, active); }}, window);
    // The registered desktop_drop plugin owns this same Flutter child HWND.
    // It remains installed for its normal lifecycle, but imports are handled
    // here for both Unicode text and files across the complete client area.
    for (HWND target : {flutter_view, window}) {
      if (!target || std::find(drop_windows.begin(), drop_windows.end(), target) != drop_windows.end()) continue;
      RevokeDragDrop(target);
      if (SUCCEEDED(RegisterDragDrop(target, drop_target))) drop_windows.push_back(target);
    }
  }
  if (import_view) SetWindowSubclass(import_view, PasteSubclass, kPasteSubclass, 0);
  UpdateInteractionChanged();
}

bool HandleGlobalSendWindowMessage(UINT message, WPARAM wparam, LPARAM lparam,
                                  LRESULT* result) {
  update_interaction.Observe(owner, message, wparam);
  if (message == kCompleteUpdateExit && update_launch && owner) {
    if (update_exit.Complete(UpdateInteracting())) DestroyWindow(owner);
    *result = 0;
    return true;
  }
  if (message == GlobalSendUpdateExitMessage() || message == kResumeUpdateExit) {
    // A cancelled helper can finish extraction after a manual retry began.
    // Only the helper belonging to this attempt may request process shutdown.
    if (message == GlobalSendUpdateExitMessage() &&
        (!update_launch || wparam != update_launch->ExitToken())) {
      *result = 0;
      return true;
    }
    if (message == GlobalSendUpdateExitMessage() && update_launch) update_exit.Request();
    if (channel && window_lifecycle && update_launch && update_exit.Prepare(UpdateInteracting())) {
      const auto attempt = update_launch;
      const auto state = window_lifecycle->State();
      auto cancel = [attempt] {
        if (update_launch == attempt) CancelUpdateAttempt(true);
      };
      channel->InvokeMethod("prepareUpdateExit", std::make_unique<Value>(Map{
          {Value("left"), Value(state.left)}, {Value("top"), Value(state.top)},
          {Value("width"), Value(state.width)}, {Value("height"), Value(state.height)},
          {Value("maximized"), Value(state.maximized)}}),
          std::make_unique<flutter::MethodResultFunctions<Value>>(
            [attempt, cancel](const Value* value) {
              if (update_launch != attempt) return;
              const auto* accepted = value ? std::get_if<bool>(value) : nullptr;
              const bool interacting = UpdateInteracting();
              if (update_exit.Resolve(accepted && *accepted, interacting) && owner)
                PostMessageW(owner, kCompleteUpdateExit, 0, 0);
              else if (interacting || update_exit.FreshCheckNeeded()) UpdateInteractionChanged();
              else cancel();
            },
            [cancel](const std::string&, const std::string&, const Value*) { cancel(); },
            cancel));
    }
    *result = 0;
    return true;
  }
  if (HandleNativePaste(message, wparam)) { *result = 0; return true; }
  if (message == kDestroyReceiveDock) {
    if (receive_dock && receive_dock->Generation() == static_cast<int64_t>(wparam)) {
      if (receive_dock->ClosingFinished()) {
        if (!receive_dock->Interacting()) {
          CompleteDockReplies();
          receive_dock->ClearContent();
        }
      }
      else receive_dock->HideAnimated();
    }
    *result = 0;
    return true;
  }
  if (message == WM_APP + 73 && LOWORD(lparam) == NIN_BALLOONUSERCLICK && channel &&
      !(window_lifecycle && window_lifecycle->UpdateNotice())) {
    channel->InvokeMethod("receivedNotificationOpened", std::make_unique<Value>());
  }
  return window_lifecycle && window_lifecycle->Handle(message, wparam, lparam, result);
}

void ShowGlobalSendWindowOnFirstFrame() {
  SignalGlobalSendUpdateReady();
  if (window_lifecycle) window_lifecycle->ShowOnFirstFrame();
}

bool HandleGlobalSendMessage(UINT message) {
  if (message != WM_CLIPBOARDUPDATE || !watching || !channel) return false;
  if (!OpenClipboard(owner)) return true;
  const bool private_content = ClipboardPrivate();
  const auto text = private_content ? std::wstring() : ReadClipboardText(CF_UNICODETEXT, 8193);
  const auto marker = ReadClipboardText(origin_format, 300);
  const auto kind = GlobalSendClipboardKind();
  flutter::EncodableList files;
  if (!private_content && marker.empty())
    for (const auto& path : ReadGlobalSendClipboardPaths()) files.emplace_back(Utf8FromUtf16(path.c_str()));
  const auto sequence = GetClipboardSequenceNumber(); CloseClipboard();
  Map event{{Value("text"), Value(Utf8FromUtf16(text.c_str()))}, {Value("private"), Value(private_content)}, {Value("marker"), Value(Utf8FromUtf16(marker.c_str()))}, {Value("sequence"), Value(static_cast<int64_t>(sequence))}};
  event[Value("files")] = Value(files);
  event[Value("kind")] = Value(kind);
  channel->InvokeMethod("clipboardChanged", std::make_unique<Value>(event)); return true;
}

void UnregisterGlobalSendSystem() {
  update_exit.Cancel();
  ++update_request;
  if (import_view) RemoveWindowSubclass(import_view, PasteSubclass, kPasteSubclass);
  native_paste_key_down = false;
  CompleteDockReplies();
  receive_dock.reset();
  receive_serial = -1;
  copied_reference_revision = -1;
  SetGlobalSendLaunchConsumer({});
  window_lifecycle.reset();
  update_launch.reset();
  update_starting = false;
  ++system_generation;
  UnregisterGlobalSendTouchDrag();
  for (HWND target : drop_windows) RevokeDragDrop(target);
  drop_windows.clear();
  if (drop_target) { drop_target->Release(); drop_target = nullptr; }
  outgoing_drag = false;
  outgoing_source_window = nullptr;
  import_view = nullptr;
  queue_drop = {};
  PublishDrag(false);
  if (watching && owner) RemoveClipboardFormatListener(owner);
  watching = false; channel.reset(); owner = nullptr;
  if (ole_initialized) OleUninitialize(); ole_initialized = false;
}
