#include "touch_drag.h"
#include "drag_preview.h"
#include <commctrl.h>
#include <tpcshrd.h>
#include <roapi.h>
#include <dragdropinterop.h>
#include <winrt/Windows.ApplicationModel.DataTransfer.h>
#include <winrt/Windows.ApplicationModel.DataTransfer.DragDrop.Core.h>
#include <winrt/Windows.Foundation.Collections.h>
#include <winrt/Windows.Storage.h>
#include <winrt/Windows.Storage.Streams.h>
#include <winrt/Windows.Graphics.Imaging.h>
#include <memory>
#include <map>
#include <thread>
#include <mutex>
#include <cstdio>
#include <stdexcept>
#include <utility>

namespace {
bool IsPromotedPointerMouse(ULONG_PTR marker) {
  // Documented Tablet PC signature: the low byte identifies the touch/pen.
  return (marker & 0xffffff00) == 0xff515700;
}
}

namespace {
using namespace winrt::Windows::ApplicationModel::DataTransfer;
using namespace winrt::Windows::ApplicationModel::DataTransfer::DragDrop::Core;
using namespace winrt::Windows::Storage;
HWND view_window = nullptr, owner_window = nullptr;
std::map<HWND, std::pair<HWND, HWND>> observed_windows;
UINT32 contact = 0;
uint64_t contact_sequence = 0;
POINT contact_point{};
bool contact_primary = false;
DWORD promoted_mouse_buttons = 0, physical_mouse_buttons = 0;
uint64_t promoted_contact_sequence = 0;
HWND promoted_mouse_owner = nullptr;
constexpr UINT kDesktopPreviewPrepared = WM_APP + 128;
uint64_t desktop_prepare_serial = 0;
GlobalSendPointerInfoReader read_pointer = GetPointerInfo;
struct Operation {
  UINT32 pointer = 0;
  uint64_t contact_sequence = 0;
  bool starting = false;
  bool desktop = false;
  bool system_promoted = false;
  bool prepared = false;
  bool cancelled = false;
  HWND source_owner = nullptr;
  uint64_t prepare_serial = 0;
  std::mutex preview_mutex;
  HBITMAP preview = nullptr;
  std::string prepare_error;
  std::function<HRESULT(HBITMAP, DWORD*)> run_drag;
  std::function<void(bool, const std::string&)> completed;
  winrt::Windows::Foundation::IAsyncOperation<DataPackageOperation> pending{nullptr};
  ~Operation() { if (preview) DeleteObject(preview); }
};
std::shared_ptr<Operation> operation;
using PointerConverter=BOOL(WINAPI*)();
#ifdef GLOBALSEND_TOUCH_DRAG_TESTING
std::function<BOOL()> convert_pointer;
#else
// Microsoft documents this Win11 API by its User32 ordinal. Resolve it once;
// Older systems keep physical mouse dragging, not a simulated touch fallback.
const auto convert_pointer = []() -> PointerConverter {
  OSVERSIONINFOEXW version{sizeof(OSVERSIONINFOEXW)};
  version.dwBuildNumber=22000;
  if(!VerifyVersionInfoW(&version,VER_BUILDNUMBER,
      VerSetConditionMask(0,VER_BUILDNUMBER,VER_GREATER_EQUAL)))return nullptr;
  const auto user32 = GetModuleHandleW(L"user32.dll");
  auto address = GetProcAddress(user32, "ConvertPrimaryPointerToMouseDrag");
  if (!address) address = GetProcAddress(user32, MAKEINTRESOURCEA(2811));
  return reinterpret_cast<PointerConverter>(address);
}();
#endif
bool MouseButtonsAvailable(HWND source, DWORD pressed) {
  physical_mouse_buttons &= pressed;
  const DWORD own_promotion = contact && contact_primary && owner_window == source &&
      promoted_mouse_owner == source && promoted_contact_sequence == contact_sequence
      ? promoted_mouse_buttons : 0;
  return !(pressed & physical_mouse_buttons) && !(pressed & ~own_promotion);
}
DWORD AsyncMouseButtons() {
  DWORD pressed = 0;
  const bool swapped = GetSystemMetrics(SM_SWAPBUTTON) != 0;
  if (GetAsyncKeyState(VK_LBUTTON) & 0x8000) pressed |= swapped ? MK_RBUTTON : MK_LBUTTON;
  if (GetAsyncKeyState(VK_RBUTTON) & 0x8000) pressed |= swapped ? MK_LBUTTON : MK_RBUTTON;
  if (GetAsyncKeyState(VK_MBUTTON) & 0x8000) pressed |= MK_MBUTTON;
  if (GetAsyncKeyState(VK_XBUTTON1) & 0x8000) pressed |= MK_XBUTTON1;
  if (GetAsyncKeyState(VK_XBUTTON2) & 0x8000) pressed |= MK_XBUTTON2;
  return pressed;
}
std::function<bool(HWND)> input_available = [](HWND source) {
  // Async button bits do not identify their device. A signed compatibility
  // DOWN from this exact held contact is ours, not an unrelated mouse press.
  if (!MouseButtonsAvailable(source, AsyncMouseButtons())) return false;
  // An external mouse capture may be an existing drag or resize. Never take it.
  const HWND foreground = GetForegroundWindow();
  if (!foreground || GetAncestor(foreground, GA_ROOT) != source) return false;
  GUITHREADINFO info{sizeof(GUITHREADINFO)};
  if (!GetGUIThreadInfo(GetWindowThreadProcessId(foreground, nullptr), &info)) return false;
  return !info.hwndCapture || GetAncestor(info.hwndCapture, GA_ROOT) == source;
};

void Complete(const std::shared_ptr<Operation>& state, bool copied,
    const std::string& error);

void CancelDesktop(const std::shared_ptr<Operation>& state) {
  if (!state || !state->desktop) return;
  state->cancelled = true;
  if (!state->starting) Complete(state, false, "触点已抬起或取消");
}
#ifdef GLOBALSEND_TOUCH_DRAG_TESTING
std::function<void(size_t)> prepared_for_test;
#endif

void BeginDesktopDrag(const std::shared_ptr<Operation>& state, bool already_promoted,
    const std::function<void()>& forward_input);

bool HasNativeMouseContact(const std::shared_ptr<Operation>& state) {
  return promoted_mouse_owner == state->source_owner &&
      promoted_contact_sequence == state->contact_sequence &&
      (promoted_mouse_buttons & MK_LBUTTON);
}

void ObserveMouseButton(HWND window, UINT message, WPARAM wparam, ULONG_PTR marker) {
  DWORD bit = 0;
  bool down = false;
  switch (message) {
    case WM_LBUTTONDBLCLK:
    case WM_LBUTTONDOWN: down = true; [[fallthrough]];
    case WM_LBUTTONUP: bit = MK_LBUTTON; break;
    case WM_RBUTTONDBLCLK:
    case WM_RBUTTONDOWN: down = true; [[fallthrough]];
    case WM_RBUTTONUP: bit = MK_RBUTTON; break;
    case WM_MBUTTONDBLCLK:
    case WM_MBUTTONDOWN: down = true; [[fallthrough]];
    case WM_MBUTTONUP: bit = MK_MBUTTON; break;
    case WM_XBUTTONDBLCLK:
    case WM_XBUTTONDOWN: down = true; [[fallthrough]];
    case WM_XBUTTONUP: bit = HIWORD(wparam) == XBUTTON1 ? MK_XBUTTON1 : MK_XBUTTON2; break;
    default: return;
  }
  if (!IsPromotedPointerMouse(marker)) {
    if (down) physical_mouse_buttons |= bit;
    else physical_mouse_buttons &= ~bit;
    return;
  }
  const auto found = observed_windows.find(window);
  if (found == observed_windows.end()) return;
  const HWND source = found->second.second;
  if (down) {
    // Compatibility DOWN may be queued just before the native POINTERDOWN.
    // Only the immediately following contact generation can claim that bit.
    const auto sequence = contact ? contact_sequence : contact_sequence + 1;
    if (source != promoted_mouse_owner || sequence != promoted_contact_sequence) {
      promoted_mouse_buttons = 0;
      promoted_mouse_owner = source;
      promoted_contact_sequence = sequence;
    }
    promoted_mouse_buttons |= bit;
  } else if (source == promoted_mouse_owner) {
    promoted_mouse_buttons &= ~bit;
  }
}

LRESULT CALLBACK PointerObserver(HWND window, UINT message, WPARAM wparam,
    LPARAM lparam, UINT_PTR, DWORD_PTR) {
  const auto extra = static_cast<ULONG_PTR>(GetMessageExtraInfo());
  ObserveMouseButton(window, message, wparam, extra);
  // Let Flutter own its long-press drag. Windows' press-and-hold otherwise
  // promotes the same contact into a secondary click and opens the menu first.
  // This is a policy for our HWNDs, not a user's global pen/touch setting.
  if (message == WM_TABLET_QUERYSYSTEMGESTURESTATUS) {
    return TABLET_DISABLE_PRESSANDHOLD;
  }
  if ((message == WM_RBUTTONDOWN || message == WM_RBUTTONUP ||
       message == WM_RBUTTONDBLCLK || message == WM_CONTEXTMENU) &&
      IsPromotedPointerMouse(extra)) {
    return 0;
  }
  if (message == kDesktopPreviewPrepared) {
    const auto state = operation;
    if (state && state->desktop && state->prepare_serial == static_cast<uint64_t>(wparam)) {
      std::string error;
      {
        const std::lock_guard lock(state->preview_mutex);
        error = state->prepare_error;
      }
      if (!error.empty()) Complete(state, false, "Desktop touch preparation: " + error);
      else state->prepared = true;
#ifdef GLOBALSEND_TOUCH_DRAG_TESTING
      if (state->prepared && prepared_for_test) prepared_for_test(0);
#endif
      // This posted worker reply has no native input context. Arm the export;
      // only a real pointer/mouse message may promote it and enter OLE.
    }
    return 0;
  }
  if (message == WM_POINTERDOWN || message == WM_POINTERUPDATE) {
    POINTER_INFO info{};
    if (read_pointer(GET_POINTERID_WPARAM(wparam), &info) &&
        (info.pointerType == PT_TOUCH || info.pointerType == PT_PEN) &&
        (contact == info.pointerId ||
         (message == WM_POINTERDOWN && (contact == 0 || (info.pointerFlags & POINTER_FLAG_PRIMARY))))) {
      contact = (info.pointerFlags & POINTER_FLAG_INCONTACT) &&
          !(info.pointerFlags & POINTER_FLAG_CANCELED) ? info.pointerId : 0;
      contact_point = info.ptPixelLocation; // Already physical virtual-desktop pixels.
      contact_primary = !!(info.pointerFlags & POINTER_FLAG_PRIMARY);
      if (message == WM_POINTERDOWN && contact != 0) {
        ++contact_sequence;
        if (operation && operation->desktop &&
            (operation->pointer != contact || operation->contact_sequence != contact_sequence)) {
          CancelDesktop(operation);
        }
        const auto found = observed_windows.find(window);
        if (found != observed_windows.end()) {
          view_window = found->second.first;
          owner_window = found->second.second;
        }
      }
      if (operation && operation->desktop &&
          info.pointerId == operation->pointer && contact_sequence == operation->contact_sequence) {
        if ((info.pointerFlags & POINTER_FLAG_CANCELED) || (!contact && !operation->system_promoted)) CancelDesktop(operation);
      }
    }
  } else if (message == WM_POINTERUP &&
      GET_POINTERID_WPARAM(wparam) == contact) {
    contact = 0;
    if (operation && operation->desktop && operation->pointer == GET_POINTERID_WPARAM(wparam)) {
      if (!operation->starting) CancelDesktop(operation);
    }
  } else if (message == WM_POINTERCAPTURECHANGED && GET_POINTERID_WPARAM(wparam) == contact &&
      (!operation || !operation->system_promoted) &&
      (!operation || !operation->starting || operation->desktop) && reinterpret_cast<HWND>(lparam) != view_window &&
      reinterpret_cast<HWND>(lparam) != owner_window) {
    contact = 0;
    CancelDesktop(operation);
  } else if (message == WM_POINTERLEAVE && GET_POINTERID_WPARAM(wparam) == contact &&
      (!operation || !operation->system_promoted) &&
      !IS_POINTER_INCONTACT_WPARAM(wparam)) {
    contact = 0;
    CancelDesktop(operation);
  } else if (message == WM_NCDESTROY) {
    const auto found = observed_windows.find(window);
    if (found != observed_windows.end()) DetachGlobalSendTouchDragWindow(found->second.second);
  }
  const auto state = operation;
  if (state && state->desktop && state->prepared && !state->starting &&
      contact == state->pointer && contact_sequence == state->contact_sequence &&
      owner_window == state->source_owner && contact_primary) {
    const auto found = observed_windows.find(window);
    const bool own_window = found != observed_windows.end() &&
        found->second.second == state->source_owner;
    const bool native_mouse = own_window && IsPromotedPointerMouse(extra) &&
        (message == WM_MOUSEMOVE || message == WM_LBUTTONDOWN) &&
        (wparam & MK_LBUTTON) && HasNativeMouseContact(state);
    const bool native_pointer = own_window && message == WM_POINTERUPDATE &&
        GET_POINTERID_WPARAM(wparam) == state->pointer && !HasNativeMouseContact(state);
    if (native_mouse || native_pointer) {
      // Promote before DefWindowProc can consume this pointer message; then
      // deliver Flutter's last movement before entering the nested OLE loop.
      LRESULT result = 0;
      bool forwarded = false;
      BeginDesktopDrag(state, native_mouse, [&] {
        result = DefSubclassProc(window, message, wparam, lparam);
        forwarded = true;
      });
      if (!forwarded && IsWindow(window))
        result = DefSubclassProc(window, message, wparam, lparam);
      return result;
    }
  }
  // Do not swallow pointer messages: Flutter still receives taps, scrolling
  // and long-press recognition; only the accepted long press starts export.
  return DefSubclassProc(window, message, wparam, lparam);
}

void Complete(const std::shared_ptr<Operation>& state, bool copied,
    const std::string& error) {
  if (operation != state) return;
  auto callback = std::move(state->completed);
  if (contact == state->pointer && contact_sequence == state->contact_sequence) contact = 0;
  operation.reset();
  if (callback) callback(copied, error);
}

void BeginDesktopDrag(const std::shared_ptr<Operation>& state, bool already_promoted,
    const std::function<void()>& forward_input) {
  HBITMAP preview;
  {
    const std::lock_guard lock(state->preview_mutex);
    preview = std::exchange(state->preview, nullptr);
  }
  std::string failure;
  bool copied = false;
  try {
    if (operation != state) { if (preview) DeleteObject(preview); return; }
    if (contact != state->pointer || contact_sequence != state->contact_sequence ||
        owner_window != state->source_owner || !contact_primary) {
      if (preview) DeleteObject(preview);
      Complete(state, false, "触点已抬起或取消，请保持长按并拖动");
      return;
    }
    if (!input_available(state->source_owner)) {
      if (preview) DeleteObject(preview);
      Complete(state, false, "其他鼠标操作正在进行，请松开后重试");
      return;
    }
    state->starting = true;
    if (!already_promoted && !convert_pointer) {
      if (preview) {DeleteObject(preview);preview=nullptr;}
      Complete(state,false,"此Windows版本不支持原生触屏拖出，请使用鼠标拖放");
      return;
    }
    {
      // Let Windows own the complete move/up stream. A per-POINTERUPDATE
      // SendInput loop plus a low-level hook on this OLE thread can stall input,
      // and a lost source capture previously turned a legitimate drop into cancel.
      // Conversion can synchronously hand pointer capture over to OLE.
      state->system_promoted = true;
      SetLastError(ERROR_SUCCESS);
      if (!already_promoted && !convert_pointer()) {
        const DWORD code = GetLastError();
        if (preview) {DeleteObject(preview);preview=nullptr;}
        Complete(state, false, "ConvertPrimaryPointerToMouseDrag: Windows error " +
            std::to_string(code) + " (pointer " + std::to_string(state->pointer) + ")");
        return;
      }
      forward_input();
      if (operation != state || state->cancelled) {
        if (preview) DeleteObject(preview);
        Complete(state, false, "");
        return;
      }
      DWORD effect = DROPEFFECT_NONE;
      const HRESULT result = state->run_drag(preview, &effect);
      copied = result == DRAGDROP_S_DROP && effect == DROPEFFECT_COPY && !state->cancelled;
      if (preview) {DeleteObject(preview);preview=nullptr;}
      Complete(state, copied, FAILED(result) ? "Windows原生触屏拖放失败" : "");
      return;
    }
  } catch (const winrt::hresult_error& error) {
    failure = "Desktop touch preparation: " + winrt::to_string(error.message());
  } catch (const std::exception& error) {
    failure = "Desktop touch drag: " + std::string(error.what());
  }
  if (preview) DeleteObject(preview);
  Complete(state, copied, failure);
}

winrt::fire_and_forget DragPointer(std::shared_ptr<Operation> state,
    UINT32 pointer, HWND window, std::wstring text, std::vector<std::wstring> paths) {
  const winrt::apartment_context ui;
  std::string failure;
  const char* stage = "prepare storage";
  HBITMAP preview = nullptr;
  try {
    std::vector<IStorageItem> items;
    for (const auto& path : paths) {
      const auto attributes = GetFileAttributesW(path.c_str());
      if (attributes == INVALID_FILE_ATTRIBUTES) winrt::throw_last_error();
      if (attributes & FILE_ATTRIBUTE_DIRECTORY) {
        stage = "StorageFolder.GetFolderFromPathAsync";
        items.push_back(co_await StorageFolder::GetFolderFromPathAsync(path));
      } else {
        stage = "StorageFile.GetFileFromPathAsync";
        items.push_back(co_await StorageFile::GetFileFromPathAsync(path));
      }
    }
    // Shell thumbnail work can block. Keep it off the input apartment so an
    // UP/cancel is observed before we validate the held contact below.
    stage = "prepare drag thumbnail";
    co_await winrt::resume_background();
    const HRESULT initialized = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
    preview = GlobalSendContentDragBitmap(text, paths);
    if (SUCCEEDED(initialized)) CoUninitialize();
    co_await ui;
    if (operation != state) { if (preview) DeleteObject(preview); co_return; }
#ifdef GLOBALSEND_TOUCH_DRAG_TESTING
    if (prepared_for_test) prepared_for_test(items.size());
    if (operation != state) { if (preview) DeleteObject(preview); co_return; }
#endif
    if (contact != pointer || contact_sequence != state->contact_sequence) {
      if (preview) DeleteObject(preview);
      Complete(state, false, "触点已抬起或取消，请保持长按并拖动");
      co_return;
    }
    // Associate the desktop HWND with the system drag manager. This does not
    // require XAML, a packaged app, or replacing Flutter's window input.
    stage = "CoreDragDropManager activation / IDragDropManagerInterop";
    auto interop = winrt::get_activation_factory<CoreDragDropManager, IDragDropManagerInterop>();
    CoreDragDropManager manager{nullptr};
    stage = "IDragDropManagerInterop.GetForWindow";
    winrt::check_hresult(interop->GetForWindow(window, winrt::guid_of<CoreDragDropManager>(), winrt::put_abi(manager)));
    stage = "CoreDragOperation activation";
    CoreDragOperation drag;
    stage = "CoreDragOperation.SetPointerId";
    drag.SetPointerId(pointer);
    stage = "ICoreDragOperation2.AllowedOperations";
    drag.AllowedOperations(DataPackageOperation::Copy);
    stage = "DataPackage.RequestedOperation";
    drag.Data().RequestedOperation(DataPackageOperation::Copy);
    if (paths.empty()) {
      stage = "DataPackage.SetText";
      drag.Data().SetText(text);
    } else {
      stage = "DataPackage.SetStorageItems";
      drag.Data().SetStorageItems(items, true);
    }
    if (preview) {
      BITMAP shape{};
      GetObjectW(preview, sizeof(shape), &shape);
      BITMAPINFO info{};
      info.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
      info.bmiHeader.biWidth = shape.bmWidth;
      info.bmiHeader.biHeight = -shape.bmHeight;
      info.bmiHeader.biPlanes = 1;
      info.bmiHeader.biBitCount = 32;
      std::vector<uint8_t> pixels(static_cast<size_t>(shape.bmWidth) * shape.bmHeight * 4);
      HDC dc = CreateCompatibleDC(nullptr);
      const int rows = GetDIBits(dc, preview, 0, shape.bmHeight, pixels.data(), &info, DIB_RGB_COLORS);
      DeleteDC(dc);
      DeleteObject(preview);
      preview = nullptr;
      if (rows == shape.bmHeight) {
        using namespace winrt::Windows::Graphics::Imaging;
        stage = "SoftwareBitmap activation";
        SoftwareBitmap image(BitmapPixelFormat::Bgra8, shape.bmWidth,
            shape.bmHeight, BitmapAlphaMode::Premultiplied);
        stage = "DataWriter.WriteBytes";
        winrt::Windows::Storage::Streams::DataWriter writer;
        writer.WriteBytes(pixels);
        stage = "SoftwareBitmap.CopyFromBuffer";
        image.CopyFromBuffer(writer.DetachBuffer());
        stage = "CoreDragOperation.SetDragUIContentFromSoftwareBitmap";
        drag.SetDragUIContentFromSoftwareBitmap(image,
            winrt::Windows::Foundation::Point{
                static_cast<float>(shape.bmWidth) / 2,
                static_cast<float>(shape.bmHeight) / 2});
      }
    }
    // StartAsync may synchronously transfer capture to the shell. Do not
    // confuse that handoff with capture lost while files were still loading.
    state->starting = true;
    stage = "CoreDragOperation.StartAsync";
    state->pending = drag.StartAsync();
    stage = "CoreDragOperation.StartAsync completion";
    const auto effect = co_await state->pending;
    co_await ui;
    Complete(state, effect == DataPackageOperation::Copy, "");
    co_return;
  } catch (const winrt::hresult_error& error) {
    char code[16]{};
    sprintf_s(code, "0x%08lX", static_cast<unsigned long>(error.code().value));
    failure = std::string(stage) + ": " + winrt::to_string(error.message()) + " (" + code + ")";
  }
  if (preview) DeleteObject(preview);
  co_await ui;
  if (!failure.empty()) Complete(state, false, failure);
}
}  // namespace

#ifdef GLOBALSEND_TOUCH_DRAG_TESTING
void SetGlobalSendTouchPreparedForTest(std::function<void(size_t)> prepared) {
  prepared_for_test = std::move(prepared);
}
void SetGlobalSendDesktopTouchInputAvailableForTest(std::function<bool(HWND)> available) {
  input_available = std::move(available);
}
bool GlobalSendTouchMouseButtonsAvailableForTest(HWND owner, DWORD pressed) {
  return MouseButtonsAvailable(owner, pressed);
}
#endif

void RegisterGlobalSendTouchDrag(HWND view, HWND owner, GlobalSendPointerInfoReader reader) {
  UnregisterGlobalSendTouchDrag();
  view_window = view; owner_window = owner;
  contact = 0;
  promoted_mouse_buttons = physical_mouse_buttons = 0;
  promoted_mouse_owner = nullptr;
  read_pointer = reader;
  AttachGlobalSendTouchDragWindow(view, owner);
}

void AttachGlobalSendTouchDragWindow(HWND view, HWND owner) {
  if (view) {
    observed_windows[view] = {view, owner};
    SetWindowSubclass(view, PointerObserver, 7820, 0);
  }
  if (owner && owner != view) {
    observed_windows[owner] = {view, owner};
    SetWindowSubclass(owner, PointerObserver, 7820, 0);
  }
}

void DetachGlobalSendTouchDragWindow(HWND owner) {
  for (auto it = observed_windows.begin(); it != observed_windows.end();) {
    if (it->second.second != owner) { ++it; continue; }
    RemoveWindowSubclass(it->first, PointerObserver, 7820);
    it = observed_windows.erase(it);
  }
  if (owner_window != owner) return;
  contact = 0;
  view_window = owner_window = nullptr;
  auto state = std::move(operation);
  if (state) {
    CancelDesktop(state);
    state->completed = {};
    if (state->pending) state->pending.Cancel();
  }
}

bool HasGlobalSendTouchContact() {
  // GetPointerInfo is message-scoped. By the asynchronous Dart long-press
  // callback its data can be ERROR_NO_DATA even while the finger is held.
  // Keep the down/update state until up, cancellation or capture loss instead.
  return contact != 0;
}

bool GlobalSendHeldTouchPoint(HWND owner, POINT* screen_point) {
  if (!contact || owner_window != owner) return false;
  *screen_point = contact_point;
  return true;
}

void StartGlobalSendTouchDrag(std::wstring text, std::vector<std::wstring> paths,
    std::function<void(bool, const std::string&)> completed) {
  if (operation) { completed(false, "已有拖拽正在进行"); return; }
  if (!HasGlobalSendTouchContact()) { completed(false, "请长按后保持接触并拖动"); return; }
  operation = std::make_shared<Operation>();
  operation->pointer = contact;
  operation->contact_sequence = contact_sequence;
  operation->completed = std::move(completed);
  DragPointer(operation, operation->pointer, owner_window, std::move(text), std::move(paths));
}

void StartGlobalSendDesktopTouchDrag(std::wstring text,
    std::vector<std::wstring> paths, HWND source_owner,
    std::function<HRESULT(HBITMAP, DWORD*)> run_drag,
    std::function<void(bool, const std::string&)> completed,
    std::function<HBITMAP()> prepare_preview) {
  if (operation) { completed(false, "已有拖拽正在进行"); return; }
  if (!contact || !contact_primary || owner_window != source_owner) {
    completed(false, "请长按后保持接触并拖动"); return;
  }
  if (!input_available(source_owner)) {
    completed(false, "其他鼠标操作正在进行，请松开后重试"); return;
  }
  operation = std::make_shared<Operation>();
  operation->desktop = true;
  operation->source_owner = source_owner;
  operation->pointer = contact;
  operation->contact_sequence = contact_sequence;
  operation->completed = std::move(completed);
  operation->prepare_serial = ++desktop_prepare_serial;
  operation->run_drag = std::move(run_drag);
  const auto state = operation;
  try {
    std::thread([state, text = std::move(text), paths = std::move(paths),
        prepare_preview = std::move(prepare_preview)] {
      // This worker owns its COM apartment. Return to the UI with a window
      // message, not apartment_context after CoUninitialize (which would make
      // continuation marshaling fail on a fresh threadpool thread).
      const HRESULT initialized = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
      HBITMAP bitmap = nullptr;
      std::string error;
      try { bitmap = prepare_preview ? prepare_preview() : GlobalSendContentDragBitmap(text, paths); }
      catch (const std::exception& failure) { error = failure.what(); }
      if (SUCCEEDED(initialized)) CoUninitialize();
      {
        const std::lock_guard lock(state->preview_mutex);
        state->preview = bitmap;
        state->prepare_error = std::move(error);
      }
      // A destroyed source drops this message. Shared state then owns/deletes
      // its bitmap; no raw payload allocation can leak behind a dead HWND.
      PostMessageW(state->source_owner, kDesktopPreviewPrepared,
          static_cast<WPARAM>(state->prepare_serial), 0);
    }).detach();
  } catch (const std::exception& failure) {
    Complete(state, false, std::string("Desktop touch preparation: ") + failure.what());
  }
}

bool GlobalSendDesktopTouchDragCancelled() {
  return !operation || !operation->desktop || operation->cancelled;
}

HRESULT GlobalSendDesktopTouchDragStatus(BOOL escape, DWORD mouse_keys) {
  if (escape || GlobalSendDesktopTouchDragCancelled()) return DRAGDROP_S_CANCEL;
  return (mouse_keys & MK_LBUTTON) ? S_OK : DRAGDROP_S_DROP;
}

void UnregisterGlobalSendTouchDrag() {
  for (const auto& entry : observed_windows) RemoveWindowSubclass(entry.first, PointerObserver, 7820);
  observed_windows.clear();
  contact = 0; view_window = owner_window = nullptr;
  promoted_mouse_buttons = physical_mouse_buttons = 0;
  promoted_mouse_owner = nullptr;
  read_pointer = GetPointerInfo;
  auto state = std::move(operation);
  if (state) {
    CancelDesktop(state);
    state->completed = {};
    if (state->pending) state->pending.Cancel();
  }
}
#ifdef GLOBALSEND_TOUCH_DRAG_TESTING
void SetGlobalSendPointerConversionForTest(std::function<BOOL()> converter) {
  convert_pointer=std::move(converter);
}
#endif
