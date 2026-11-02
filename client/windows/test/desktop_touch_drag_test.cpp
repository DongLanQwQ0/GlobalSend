#include "../runner/touch_drag.h"
#include <winrt/Windows.Foundation.h>
#include <tpcshrd.h>
#include <cassert>
#include <iostream>
#include <stdexcept>
#include <utility>

namespace {
UINT dispatch_message = 0;
UINT32 flags = POINTER_FLAG_PRIMARY | POINTER_FLAG_INCONTACT;
POINTER_INPUT_TYPE pointer_type = PT_TOUCH;
int forwarded_right = 0, forwarded_context = 0;
WNDPROC original_view_proc = nullptr;
LRESULT CALLBACK RecordViewMessage(HWND window, UINT message, WPARAM wp, LPARAM lp) {
  if (message == WM_RBUTTONDOWN || message == WM_RBUTTONUP) ++forwarded_right;
  if (message == WM_CONTEXTMENU) ++forwarded_context;
  return CallWindowProcW(original_view_proc, window, message, wp, lp);
}
BOOL WINAPI ReadPointer(UINT32 id, POINTER_INFO* info) {
  assert(dispatch_message == WM_POINTERDOWN || dispatch_message == WM_POINTERUPDATE ||
      dispatch_message == WM_POINTERUP);
  *info = {};
  info->pointerId = id;
  info->pointerType = pointer_type;
  info->pointerFlags = flags;
  info->ptPixelLocation = {120, 140};
  return TRUE;
}
void Message(HWND window, UINT message, WPARAM wp = 0, LPARAM lp = 0,
    LONG_PTR marker = 0) {
  const auto previous_message = std::exchange(dispatch_message, message);
  const auto previous_extra = SetMessageExtraInfo(marker);
  SendMessageW(window, message, wp, lp);
  SetMessageExtraInfo(previous_extra);
  dispatch_message = previous_message;
}
void Pointer(HWND window, UINT message, UINT32 id = 7,
    UINT32 state = POINTER_FLAG_PRIMARY | POINTER_FLAG_INCONTACT) {
  flags = state;
  Message(window, message, MAKEWPARAM(id, 0));
}
void Pump(const bool& done) {
  const auto end = GetTickCount64() + 10000;
  while (!done && GetTickCount64() < end) {
    MSG message{};
    while (PeekMessageW(&message, nullptr, 0, 0, PM_REMOVE)) DispatchMessageW(&message);
    if (!done) MsgWaitForMultipleObjectsEx(0, nullptr, 10, QS_ALLINPUT, MWMO_INPUTAVAILABLE);
  }
  assert(done);
}
}

// Hidden windows only. Converter/OLE are replaced: no input injection, hooks,
// cursor movement, clipboard access or interaction with another application.
int main() {
  winrt::init_apartment(winrt::apartment_type::single_threaded);
  HWND owner = CreateWindowExW(0, L"STATIC", L"Hidden touch fixture", 0,
      0, 0, 320, 240, nullptr, nullptr, GetModuleHandleW(nullptr), nullptr);
  HWND view = CreateWindowExW(0, L"STATIC", L"Hidden view", WS_CHILD,
      0, 0, 320, 240, owner, nullptr, GetModuleHandleW(nullptr), nullptr);
  HWND dock = CreateWindowExW(0, L"STATIC", L"Hidden dock", 0,
      0, 0, 100, 100, nullptr, nullptr, GetModuleHandleW(nullptr), nullptr);
  assert(owner && view && dock);
  original_view_proc = reinterpret_cast<WNDPROC>(SetWindowLongPtrW(view,
      GWLP_WNDPROC, reinterpret_cast<LONG_PTR>(RecordViewMessage)));
  RegisterGlobalSendTouchDrag(view, owner, ReadPointer);
  AttachGlobalSendTouchDragWindow(dock, dock);
  assert(SendMessageW(view, WM_TABLET_QUERYSYSTEMGESTURESTATUS, 0, 0) &
      TABLET_DISABLE_PRESSANDHOLD);
  for (const auto marker : {LONG_PTR{0xff515780}, LONG_PTR{0xff515700}}) {
    Message(view, WM_RBUTTONDOWN, MK_RBUTTON, 0, marker);
    Message(view, WM_RBUTTONUP, 0, 0, marker);
    Message(view, WM_CONTEXTMENU, 0, 0, marker);
    assert(forwarded_right == 0 && forwarded_context == 0);
    Pointer(view, WM_POINTERDOWN);
    Message(view, WM_LBUTTONDOWN, MK_LBUTTON, 0, marker);
    assert(GlobalSendTouchMouseButtonsAvailableForTest(owner, MK_LBUTTON));
    assert(!GlobalSendTouchMouseButtonsAvailableForTest(owner, MK_LBUTTON | MK_MBUTTON));
    Message(view, WM_LBUTTONDOWN, MK_LBUTTON); // Physical mouse, not this contact.
    assert(!GlobalSendTouchMouseButtonsAvailableForTest(owner, MK_LBUTTON));
    Message(view, WM_LBUTTONUP);
    assert(GlobalSendTouchMouseButtonsAvailableForTest(owner, MK_LBUTTON));
    Pointer(view, WM_POINTERUP, 7, 0);
    Pointer(view, WM_POINTERDOWN); // Same ID cannot reuse an old promoted DOWN.
    assert(!GlobalSendTouchMouseButtonsAvailableForTest(owner, MK_LBUTTON));
    Message(view, WM_LBUTTONUP, 0, 0, marker);
    Pointer(view, WM_POINTERUP, 7, 0);
  }
  Message(view, WM_RBUTTONDOWN, MK_RBUTTON);
  Message(view, WM_RBUTTONUP);
  const int context_before_keyboard = forwarded_context;
  Message(view, WM_CONTEXTMENU, reinterpret_cast<WPARAM>(view), -1);
  assert(forwarded_right == 2 && forwarded_context == context_before_keyboard + 1);
  bool available = true;
  SetGlobalSendDesktopTouchInputAvailableForTest([&](HWND source) {
    assert(source == owner || source == dock);
    return available;
  });
  int conversions = 0;
  SetGlobalSendPointerConversionForTest([&]() -> BOOL {
    // Old code called conversion from the worker's posted WM_APP reply.
    assert(dispatch_message == WM_POINTERUPDATE);
    ++conversions;
    Message(view, WM_POINTERCAPTURECHANGED, MAKEWPARAM(7, 0));
    return TRUE;
  });
  auto never_run = [](HBITMAP, DWORD*) -> HRESULT { assert(false); return E_FAIL; };
  bool rejected = false;
  StartGlobalSendDesktopTouchDrag(L"none", {}, owner, never_run,
      [&](bool copied, const std::string& error) { rejected = !copied && !error.empty(); });
  assert(rejected);

  for (int scenario = 0; scenario < 10; ++scenario) {
    pointer_type = scenario == 1 ? PT_PEN : PT_TOUCH;
    Pointer(view, WM_POINTERDOWN);
    bool prepared = false, finished = false, copied = false;
    std::string failure;
    int runs = 0;
    const auto conversions_before = conversions;
    SetGlobalSendTouchPreparedForTest([&](size_t) { prepared = true; });
    StartGlobalSendDesktopTouchDrag(L"native", {}, owner,
        [&](HBITMAP bitmap, DWORD* effect) -> HRESULT {
          ++runs;
          assert(bitmap && dispatch_message == WM_POINTERUPDATE);
          assert(GlobalSendDesktopTouchDragStatus(FALSE, MK_LBUTTON) == S_OK);
          assert(GlobalSendDesktopTouchDragStatus(TRUE, MK_LBUTTON) == DRAGDROP_S_CANCEL);
          Message(view, WM_POINTERCAPTURECHANGED, MAKEWPARAM(7, 0));
          Message(view, WM_POINTERLEAVE, MAKEWPARAM(7, 0));
          for (int i = 0; i < 1000; ++i) Pointer(view, WM_POINTERUPDATE);
          assert(!GlobalSendDesktopTouchDragCancelled());
          if (scenario == 2) {
            Pointer(view, WM_POINTERUPDATE, 7, POINTER_FLAG_CANCELED | POINTER_FLAG_PRIMARY);
            assert(GlobalSendDesktopTouchDragStatus(FALSE, 0) == DRAGDROP_S_CANCEL);
            return DRAGDROP_S_CANCEL;
          }
          if (scenario == 3) throw std::runtime_error("mock OLE failure");
          if (scenario == 4) return E_FAIL;
          Pointer(view, WM_POINTERUP, 7, 0);
          assert(GlobalSendDesktopTouchDragStatus(FALSE, 0) == DRAGDROP_S_DROP);
          *effect = DROPEFFECT_COPY;
          return DRAGDROP_S_DROP;
        }, [&](bool result, const std::string& error) {
          copied = result; failure = error; finished = true;
        });
    Pump(prepared);
    assert(runs == 0 && conversions == conversions_before && !finished);
    Message(view, WM_MOUSEMOVE, MK_LBUTTON); // Unmarked physical mouse cannot own it.
    assert(runs == 0);
    if (scenario == 5) Pointer(view, WM_POINTERUP, 7, 0);
    else if (scenario == 6) Message(view, WM_POINTERCAPTURECHANGED, MAKEWPARAM(7, 0));
    else if (scenario == 7) {
      Pointer(view, WM_POINTERUP, 7, 0);
      Pointer(view, WM_POINTERDOWN, 7); // Recycled ID cannot start old payload.
    } else if (scenario == 8) {
      available = false;
      Pointer(view, WM_POINTERUPDATE);
    } else if (scenario == 9) {
      Pointer(view, WM_POINTERUPDATE, 7, POINTER_FLAG_CANCELED | POINTER_FLAG_PRIMARY);
    } else Pointer(view, WM_POINTERUPDATE);
    Pump(finished);
    available = true;
    assert(runs == (scenario <= 4 ? 1 : 0));
    assert(copied == (scenario == 0 || scenario == 1));
    assert(failure.empty() == (scenario <= 2));
    Pointer(view, WM_POINTERUP, 7, 0);
    std::cout << "native message-context scenario " << scenario << " passed\n";
  }

  // Already system-promoted contacts must not be converted a second time.
  for (int scenario = 0; scenario < 3; ++scenario) {
    HWND source = scenario == 2 ? dock : owner;
    HWND input = scenario == 2 ? dock : view;
    Pointer(input, WM_POINTERDOWN);
    Message(input, WM_LBUTTONDOWN, MK_LBUTTON, 0, 0xff515780);
    assert(GlobalSendTouchMouseButtonsAvailableForTest(source, MK_LBUTTON));
    assert(!GlobalSendTouchMouseButtonsAvailableForTest(source == owner ? dock : owner, MK_LBUTTON));
    bool prepared = false, finished = false;
    int runs = 0;
    SetGlobalSendTouchPreparedForTest([&](size_t) { prepared = true; });
    SetGlobalSendPointerConversionForTest([]() -> BOOL { assert(false); return FALSE; });
    StartGlobalSendDesktopTouchDrag(L"already native", {}, source,
        [&](HBITMAP bitmap, DWORD* effect) -> HRESULT {
          ++runs;
          assert(bitmap && dispatch_message == WM_MOUSEMOVE);
          Pointer(input, WM_POINTERUP, 7, 0);
          assert(GlobalSendDesktopTouchDragStatus(FALSE, 0) == DRAGDROP_S_DROP);
          *effect = DROPEFFECT_COPY;
          return DRAGDROP_S_DROP;
        }, [&](bool copied, const std::string& error) {
          assert(copied && error.empty()); finished = true;
        });
    Pump(prepared);
    Pointer(input, WM_POINTERUPDATE);
    assert(runs == 0 && !finished);
    Message(input, WM_MOUSEMOVE, MK_LBUTTON, 0, scenario == 1 ? 0xff515700 : 0xff515780);
    assert(runs == 1 && finished);
    Message(input, WM_LBUTTONUP, 0, 0, 0xff515780);
  }

  // Preserve native error information and release the failed operation.
  Pointer(view, WM_POINTERDOWN);
  bool prepared = false, finished = false;
  SetGlobalSendTouchPreparedForTest([&](size_t) { prepared = true; });
  SetGlobalSendPointerConversionForTest([]() -> BOOL {
    assert(dispatch_message == WM_POINTERUPDATE);
    SetLastError(ERROR_INVALID_PARAMETER);
    return FALSE;
  });
  StartGlobalSendDesktopTouchDrag(L"failure", {}, owner, never_run,
      [&](bool copied, const std::string& error) {
        assert(!copied && error.find("Windows error 87") != std::string::npos);
        finished = true;
      });
  Pump(prepared);
  Pointer(view, WM_POINTERUPDATE);
  assert(finished);

  // UP before background readback finishes completes now; a late worker reply
  // cannot enter OLE or consume a newer contact with a recycled pointer ID.
  HANDLE entered = CreateEventW(nullptr, TRUE, FALSE, nullptr);
  HANDLE release = CreateEventW(nullptr, TRUE, FALSE, nullptr);
  HANDLE worker_left = CreateEventW(nullptr, TRUE, FALSE, nullptr);
  assert(entered && release && worker_left);
  Pointer(view, WM_POINTERDOWN);
  int callbacks = 0;
  StartGlobalSendDesktopTouchDrag(L"slow", {}, owner, never_run,
      [&](bool copied, const std::string& error) {
        assert(!copied && !error.empty()); ++callbacks;
      }, [=]() -> HBITMAP {
        SetEvent(entered);
        assert(WaitForSingleObject(release, 10000) == WAIT_OBJECT_0);
        HBITMAP bitmap = CreateBitmap(1, 1, 1, 32, nullptr);
        SetEvent(worker_left);
        return bitmap;
      });
  assert(WaitForSingleObject(entered, 10000) == WAIT_OBJECT_0);
  Pointer(view, WM_POINTERUP, 7, 0);
  assert(callbacks == 1);
  Pointer(view, WM_POINTERDOWN);
  prepared = false; finished = false;
  SetGlobalSendPointerConversionForTest([]() -> BOOL {
    assert(dispatch_message == WM_POINTERUPDATE); return TRUE;
  });
  StartGlobalSendDesktopTouchDrag(L"new generation", {}, owner,
      [&](HBITMAP bitmap, DWORD* effect) -> HRESULT {
        assert(bitmap); *effect = DROPEFFECT_COPY; return DRAGDROP_S_DROP;
      }, [&](bool copied, const std::string& error) {
        assert(copied && error.empty()); finished = true;
      });
  SetEvent(release);
  assert(WaitForSingleObject(worker_left, 10000) == WAIT_OBJECT_0);
  Pump(prepared);
  assert(!finished && callbacks == 1);
  Pointer(view, WM_POINTERUPDATE);
  assert(finished && callbacks == 1);
  CloseHandle(entered); CloseHandle(release); CloseHandle(worker_left);

  // A source destroyed inside nested OLE cancels without replying to a dead
  // Flutter engine. Only the fixture's hidden view is affected.
  Pointer(view, WM_POINTERDOWN);
  prepared = false;
  bool destroyed = false;
  StartGlobalSendDesktopTouchDrag(L"destroy", {}, owner,
      [&](HBITMAP, DWORD*) -> HRESULT {
        DestroyWindow(view);
        assert(GlobalSendDesktopTouchDragCancelled());
        destroyed = true;
        return DRAGDROP_S_CANCEL;
      }, [](bool, const std::string&) { assert(false); });
  Pump(prepared);
  Pointer(view, WM_POINTERUPDATE);
  assert(destroyed);
  SetGlobalSendTouchPreparedForTest({});
  UnregisterGlobalSendTouchDrag();
  DestroyWindow(view); DestroyWindow(owner); DestroyWindow(dock);
  winrt::uninit_apartment();
  std::cout << "PASS: native input dispatch, existing system promotion, async preview readiness, 1000 moves, drop/cancel/errors, contact generation and main/dock ownership\n";
}
