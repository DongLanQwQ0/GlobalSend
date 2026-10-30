#include "system_integration.h"
#include "utils.h"
#include "drop_target.h"
#include "touch_drag.h"
#include "clipboard_content.h"
#include "shell_file.h"
#include "window_lifecycle.h"
#include "autostart.h"
#include <system_error>
#include "single_instance.h"
#include "drag_preview.h"
#include "receive_dock.h"
#include "queue_drop_region.h"
#include "local_ip_interfaces.h"
#include <winrt/Windows.Foundation.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>
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
  if (HandleNativePaste(message, key)) return 0;
  return DefSubclassProc(window, message, key, data);
}
GlobalSendQueueDropRegion queue_drop;
std::vector<std::pair<std::string, RECT>> device_drop_regions;
std::string drop_server_key;
std::string DeviceDropAt(POINTL screen);
uint64_t drop_sequence = 0;
uint64_t system_generation = 0;
constexpr UINT kDestroyReceiveDock = WM_APP + 119;
std::unique_ptr<GlobalSendReceiveDock> receive_dock;
int64_t receive_serial = -1;
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

void PublishDrag(bool active) {
  if (!channel) return;
  Map event{{Value("active"), Value(active)}, {Value("importing"), Value(false)},
    {Value("local"), Value(outgoing_drag)}};
  channel->InvokeMethod("nativeDrag", std::make_unique<Value>(event));
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

void Drag(const Map& arguments, std::unique_ptr<flutter::MethodResult<Value>> result, HWND source_window) {
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
  std::function<HBITMAP()> prepare_preview;
  const auto rgba = arguments.find(Value("previewRgba"));
  if (rgba != arguments.end()) {
    if (const auto* pixels = std::get_if<std::vector<uint8_t>>(&rgba->second)) {
      const auto number = [&arguments](const char* key) {
        const auto entry = arguments.find(Value(key));
        if (entry == arguments.end()) return 0;
        if (const auto* value = std::get_if<int32_t>(&entry->second)) return *value;
        return 0;
      };
      prepare_preview = [pixels = *pixels, width = number("previewWidth"),
          height = number("previewHeight")] {
        return GlobalSendDragBitmapFromRgba(pixels, width, height);
      };
    }
  }
  IDataObject* payload = nullptr;
  if (FAILED(CreateGlobalSendDragData(format, bytes, &payload))) {
    result->Error("DRAG_DATA", "Windows could not prepare drag content");
    return;
  }
  const bool pointer_export = pointer_kind == "touch" || pointer_kind == "stylus" ||
      pointer_kind == "invertedStylus";
  if (pointer_export || (pointer_kind != "mouse" && HasGlobalSendTouchContact())) {
      // A held native primary contact drives this explicit desktop adapter.
      // Do not retry the WinRT CoreWindow path or use the plain mouse path.
      auto data = std::shared_ptr<IDataObject>(payload,
          [](IDataObject* value) { value->Release(); });
      auto source = std::shared_ptr<DragSource>(new DragSource(true),
          [](DragSource* value) { value->Release(); });
    auto completion = std::shared_ptr<flutter::MethodResult<Value>>(std::move(result));
      StartGlobalSendDesktopTouchDrag(std::move(export_text), std::move(export_paths), source_window,
        [data, source, source_window](HBITMAP bitmap, DWORD* effect) {
          InitializeGlobalSendDragPreviewFromBitmap(data.get(), source_window, bitmap);
          outgoing_drag = true;
          outgoing_source_window = source_window;
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
      }, std::move(prepare_preview));
    return;
  }
  auto* data = payload; auto* source = new DragSource();
  HBITMAP bitmap = prepare_preview ? prepare_preview() : GlobalSendContentDragBitmap(export_text, export_paths);
  InitializeGlobalSendDragPreviewFromBitmap(data, source_window, bitmap);
  if (bitmap) DeleteObject(bitmap);
  DWORD effect = DROPEFFECT_NONE;
  outgoing_drag = true;
  outgoing_source_window = source_window;
  HRESULT status = DoDragDrop(data, source, DROPEFFECT_COPY, &effect);
  PublishDrag(false);
  outgoing_drag = false;
  outgoing_source_window = nullptr;
  data->Release(); source->Release();
  if (status == DRAGDROP_S_DROP || status == DRAGDROP_S_CANCEL) result->Success(Value(status == DRAGDROP_S_DROP && effect == DROPEFFECT_COPY));
  else result->Error("DRAG_FAILED", "Windows OLE drag could not start");
}
bool PrepareReceiveDock(Map payload) {
  if (receive_dock) return true;
  receive_dock = std::make_unique<GlobalSendReceiveDock>(std::move(payload),
    [](const Map& action) {
      if (channel) channel->InvokeMethod("receiveDockAction", std::make_unique<Value>(action));
      if (String(action, "action") == "close") CloseDockLater(Integer(action, "arrivalGeneration"));
    }, [](const Map& values, auto completion, HWND window) {
      Drag(values, std::move(completion), window);
    }, [] { CompleteDockReplies(); }, [](int64_t generation) {
      PostMessageW(owner, kDestroyReceiveDock, static_cast<WPARAM>(generation), 0);
    });
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
      result->Success(Value(args && window_lifecycle && window_lifecycle->NotifyReceived(
          L"GlobalSend 有新版本", Wide(String(*args, "version")) + L" 可更新，点击查看", true)));
      return;
    }
    const auto* arguments = call.arguments() ? std::get_if<Map>(call.arguments()) : nullptr;
    if (!arguments) { result->Error("BAD_ARGUMENT", "Expected operation map"); return; }
    if (call.method_name() == "presentReceiveDock") {
      auto payload = *arguments;
      const auto serial = Integer(payload, "serial");
      if (serial != receive_serial) {
        receive_serial = serial;
        if (window_lifecycle) window_lifecycle->ShowReceived();
      }
      const auto generation = static_cast<int64_t>(window_lifecycle
          ? window_lifecycle->ReceiptArrivalGeneration() : 0);
      payload[Value("arrivalGeneration")] = Value(generation);
      const auto items = payload.find(Value("items"));
      const auto* entries = items == payload.end() ? nullptr :
          std::get_if<flutter::EncodableList>(&items->second);
      if (!entries || entries->empty()) {
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
    } else if (call.method_name() == "readClipboard") {
      const auto content = ReadGlobalSendClipboard(owner, Wide(String(*arguments, "bitmapPath")));
      if (!content.error.empty()) { result->Error("CLIPBOARD_READ", content.error); return; }
      flutter::EncodableList paths, texts, temporary;
      for (const auto& path : content.paths) paths.emplace_back(Utf8FromUtf16(path.c_str()));
      for (const auto& text : content.texts) texts.emplace_back(Utf8FromUtf16(text.c_str()));
      for (const auto& path : content.temporary_paths) temporary.emplace_back(Utf8FromUtf16(path.c_str()));
      result->Success(Value(Map{{Value("paths"),Value(paths)}, {Value("texts"),Value(texts)}, {Value("temporaryPaths"),Value(temporary)}}));
    } else if (call.method_name() == "writeClipboard") {
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
      [] { return outgoing_drag; }, LocalDropAt}, window);
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
}

bool HandleGlobalSendWindowMessage(UINT message, WPARAM wparam, LPARAM lparam,
                                  LRESULT* result) {
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
  if (window_lifecycle) window_lifecycle->ShowOnFirstFrame();
}

bool HandleGlobalSendMessage(UINT message) {
  if (message != WM_CLIPBOARDUPDATE || !watching || !channel) return false;
  if (!OpenClipboard(owner)) return true;
  bool private_content = IsClipboardFormatAvailable(RegisterClipboardFormatW(L"ExcludeClipboardContentFromMonitorProcessing"));
  for (const auto* name : {L"CanIncludeInClipboardHistory", L"CanUploadToCloudClipboard"}) {
    HANDLE memory = GetClipboardData(RegisterClipboardFormatW(name));
    if (memory && GlobalSize(memory) >= sizeof(DWORD)) {
      const auto* value = static_cast<const DWORD*>(GlobalLock(memory));
      if (value) { private_content = private_content || *value == 0; GlobalUnlock(memory); }
    }
  }
  const auto text = private_content ? std::wstring() : ReadClipboardText(CF_UNICODETEXT, 8193);
  const auto marker = ReadClipboardText(origin_format, 300);
  const auto sequence = GetClipboardSequenceNumber(); CloseClipboard();
  Map event{{Value("text"), Value(Utf8FromUtf16(text.c_str()))}, {Value("private"), Value(private_content)}, {Value("marker"), Value(Utf8FromUtf16(marker.c_str()))}, {Value("sequence"), Value(static_cast<int64_t>(sequence))}};
  channel->InvokeMethod("clipboardChanged", std::make_unique<Value>(event)); return true;
}

void UnregisterGlobalSendSystem() {
  if (import_view) RemoveWindowSubclass(import_view, PasteSubclass, kPasteSubclass);
  native_paste_key_down = false;
  CompleteDockReplies();
  receive_dock.reset();
  receive_serial = -1;
  SetGlobalSendLaunchConsumer({});
  window_lifecycle.reset();
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
