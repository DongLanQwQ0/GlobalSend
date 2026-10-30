#include "../runner/touch_drag.h"
#include <winrt/Windows.Foundation.h>
#include <tpcshrd.h>
#include <cassert>
#include <iostream>
#include <stdexcept>

namespace {
POINT point{120, 140};
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
  *info = {};
  info->pointerId = id;
  info->pointerType = pointer_type;
  info->pointerFlags = flags;
  info->ptPixelLocation = point;
  return TRUE;
}
void Pointer(HWND window, UINT message, UINT32 id = 7,
    UINT32 state = POINTER_FLAG_PRIMARY | POINTER_FLAG_INCONTACT) {
  flags = state;
  SendMessageW(window, message, MAKEWPARAM(id, 0), 0);
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

int main() {
  SetErrorMode(SEM_FAILCRITICALERRORS | SEM_NOGPFAULTERRORBOX);
  std::cerr << "starting hidden mock adapter fixture\n";
  winrt::init_apartment(winrt::apartment_type::single_threaded);
  const RECT desktop{-1920, -1080, 1920, 1080};
  auto first = GlobalSendTouchMouseInput({-1920, -1080}, MOUSEEVENTF_MOVE, desktop);
  auto last = GlobalSendTouchMouseInput({1919, 1079}, MOUSEEVENTF_MOVE, desktop);
  assert(first.mi.dx == 0 && first.mi.dy == 0);
  assert(last.mi.dx == 65535 && last.mi.dy == 65535);
  assert(last.mi.dwFlags & MOUSEEVENTF_VIRTUALDESK);
  assert(last.mi.dwExtraInfo != 0);
  auto clamped = GlobalSendTouchMouseInput({-5000, 5000}, MOUSEEVENTF_MOVE, desktop);
  assert(clamped.mi.dx == 0 && clamped.mi.dy == 65535);

  HWND owner = CreateWindowExW(0, L"STATIC", L"Hidden touch adapter fixture", 0,
      0, 0, 320, 240, nullptr, nullptr, GetModuleHandleW(nullptr), nullptr);
  HWND view = CreateWindowExW(0, L"STATIC", L"Hidden view", WS_CHILD,
      0, 0, 320, 240, owner, nullptr, GetModuleHandleW(nullptr), nullptr);
  HWND dock = CreateWindowExW(0, L"STATIC", L"Hidden unrelated dock", 0,
      0, 0, 100, 100, nullptr, nullptr, GetModuleHandleW(nullptr), nullptr);
  assert(owner && view && dock);
  original_view_proc = reinterpret_cast<WNDPROC>(SetWindowLongPtrW(view,
      GWLP_WNDPROC, reinterpret_cast<LONG_PTR>(RecordViewMessage)));
  std::vector<INPUT> sent;
  bool available = true;
  bool fail_move = false;
  bool fail_down = false;
  bool foreign_on_down = false;
  SetGlobalSendDesktopTouchTestHooks([&](const INPUT& input) {
    sent.push_back(input);
    if (foreign_on_down && (input.mi.dwFlags & MOUSEEVENTF_LEFTDOWN)) {
      GlobalSendDesktopForeignMouseForTest(WM_LBUTTONDOWN);
    }
    if (fail_down && (input.mi.dwFlags & MOUSEEVENTF_LEFTDOWN)) return false;
    return !(fail_move && sent.size() > 2 && (input.mi.dwFlags & MOUSEEVENTF_MOVE) &&
        !(input.mi.dwFlags & MOUSEEVENTF_LEFTDOWN));
  }, [&](HWND expected) { assert(expected == owner || expected == dock); return available; });
  auto run = [](HBITMAP, DWORD*) -> HRESULT { assert(false); return E_FAIL; };
  RegisterGlobalSendTouchDrag(view, owner, ReadPointer);
  assert(SendMessageW(view, WM_TABLET_QUERYSYSTEMGESTURESTATUS, 0, 0) &
      TABLET_DISABLE_PRESSANDHOLD);
  const auto message_extra = GetMessageExtraInfo();
  for (const LONG_PTR marker : {LONG_PTR{0xff515780}, LONG_PTR{0xff515700}}) {
    SetMessageExtraInfo(marker);
    SendMessageW(view, WM_RBUTTONDOWN, MK_RBUTTON, MAKELPARAM(30, 40));
    SendMessageW(view, WM_RBUTTONUP, 0, MAKELPARAM(30, 40));
    SendMessageW(view, WM_CONTEXTMENU, reinterpret_cast<WPARAM>(view), MAKELPARAM(30, 40));
    assert(forwarded_right == 0 && forwarded_context == 0);
  }
  SetMessageExtraInfo(0);
  SendMessageW(view, WM_RBUTTONDOWN, MK_RBUTTON, MAKELPARAM(30, 40));
  SendMessageW(view, WM_RBUTTONUP, 0, MAKELPARAM(30, 40));
  const int physical_context_before_keyboard = forwarded_context;
  SendMessageW(view, WM_CONTEXTMENU, reinterpret_cast<WPARAM>(view), -1);
  assert(forwarded_right == 2 && forwarded_context == physical_context_before_keyboard + 1);
  SetMessageExtraInfo(message_extra);
  std::cerr << "promoted touch/pen right clicks suppressed; physical mouse and keyboard menu retained\n";
  for (const LONG_PTR marker : {LONG_PTR{0xff515780}, LONG_PTR{0xff515700}}) {
    pointer_type = marker == 0xff515780 ? PT_TOUCH : PT_PEN;
    Pointer(view, WM_POINTERDOWN, 41);
    SetMessageExtraInfo(marker);
    SendMessageW(view, WM_LBUTTONDOWN, MK_LBUTTON, MAKELPARAM(30, 40));
    SendMessageW(view, WM_RBUTTONDOWN, MK_RBUTTON, MAKELPARAM(30, 40));
    // Feed the production button predicate the high async bits that previously
    // rejected the exact same touch. The predicate is not replaced by true.
    const DWORD own_buttons = MK_LBUTTON | MK_RBUTTON;
    assert(GlobalSendTouchMouseButtonsAvailableForTest(owner, own_buttons));
    assert(!GlobalSendTouchMouseButtonsAvailableForTest(dock, own_buttons));
    assert(!GlobalSendTouchMouseButtonsAvailableForTest(owner, own_buttons | MK_MBUTTON));
    SetMessageExtraInfo(0);
    SendMessageW(view, WM_LBUTTONDOWN, MK_LBUTTON, MAKELPARAM(30, 40));
    assert(!GlobalSendTouchMouseButtonsAvailableForTest(owner, own_buttons));
    SendMessageW(view, WM_LBUTTONUP, 0, MAKELPARAM(30, 40));
    assert(GlobalSendTouchMouseButtonsAvailableForTest(owner, own_buttons));
    SendMessageW(view, WM_LBUTTONDBLCLK, MK_LBUTTON, MAKELPARAM(30, 40));
    assert(!GlobalSendTouchMouseButtonsAvailableForTest(owner, own_buttons));
    SendMessageW(view, WM_LBUTTONUP, 0, MAKELPARAM(30, 40));
    SetMessageExtraInfo(marker);
    SendMessageW(view, WM_LBUTTONUP, 0, MAKELPARAM(30, 40));
    SendMessageW(view, WM_RBUTTONUP, 0, MAKELPARAM(30, 40));
    assert(!GlobalSendTouchMouseButtonsAvailableForTest(owner, own_buttons));
    Pointer(view, WM_POINTERUP, 41, 0);
    // Compatibility DOWN may precede its native POINTERDOWN in the queue.
    SendMessageW(view, WM_LBUTTONDOWN, MK_LBUTTON, MAKELPARAM(30, 40));
    Pointer(view, WM_POINTERDOWN, 42);
    assert(GlobalSendTouchMouseButtonsAvailableForTest(owner, MK_LBUTTON));
    Pointer(view, WM_POINTERUP, 42, 0);
    assert(!GlobalSendTouchMouseButtonsAvailableForTest(owner, MK_LBUTTON));
    Pointer(view, WM_POINTERDOWN, 42);
    assert(!GlobalSendTouchMouseButtonsAvailableForTest(owner, MK_LBUTTON));
    SendMessageW(view, WM_LBUTTONUP, 0, MAKELPARAM(30, 40));
    Pointer(view, WM_POINTERUP, 42, 0);
  }
  SetMessageExtraInfo(message_extra);
  pointer_type = PT_TOUCH;
  std::cerr << "production button guard accepts only same-contact promotion; physical/unknown/stale/other-owner reject\n";
  bool denied = false;
  StartGlobalSendDesktopTouchDrag(L"text", {}, owner, run,
      [&](bool copied, const std::string& error) { denied = !copied && !error.empty(); });
  assert(denied && sent.empty());
  std::cerr << "no-contact rejected\n";
  Pointer(view, WM_POINTERDOWN);
  available = false;
  denied = false;
  StartGlobalSendDesktopTouchDrag(L"text", {}, owner, run,
      [&](bool copied, const std::string& error) { denied = !copied && !error.empty(); });
  assert(denied && sent.empty());
  std::cerr << "existing mouse/drag rejected\n";
  available = true;

  for (int scenario = 0; scenario < 17; ++scenario) {
    std::cerr << "begin scenario " << scenario << "\n";
    sent.clear(); fail_move = scenario == 6;
    fail_down = scenario == 11;
    foreign_on_down = scenario == 14;
    pointer_type = scenario == 16 ? PT_PEN : PT_TOUCH;
    Pointer(view, WM_POINTERDOWN);
    bool finished = false;
    bool copied = false;
    std::string error;
    int runs = 0;
    if (scenario == 9) SetGlobalSendTouchPreparedForTest([&](size_t) {
      Pointer(view, WM_POINTERUP, 7, 0);
      Pointer(view, WM_POINTERDOWN, 7); // Same ID, new physical contact generation.
    });
    if (scenario == 12) SetGlobalSendTouchPreparedForTest([&](size_t) { available = false; });
    if (scenario == 13) SetGlobalSendTouchPreparedForTest([&](size_t) {
      SendMessageW(view, WM_POINTERCAPTURECHANGED, MAKEWPARAM(7, 0), 0);
    });
    StartGlobalSendDesktopTouchDrag(L"fixture", {}, owner,
      [&](HBITMAP bitmap, DWORD* effect) -> HRESULT {
        ++runs;
        assert(bitmap && sent.size() == 2);
        assert(sent.front().mi.dwFlags & MOUSEEVENTF_LEFTDOWN);
        assert(!(sent.front().mi.dwFlags & MOUSEEVENTF_MOVE));
        assert(sent[1].mi.dwFlags & MOUSEEVENTF_MOVE);
        assert(!(sent[1].mi.dwFlags & MOUSEEVENTF_LEFTDOWN));
        assert(GlobalSendDesktopTouchDragStatus(FALSE) == S_OK);
        assert(GlobalSendDesktopTouchDragStatus(TRUE) == DRAGDROP_S_CANCEL);
        if (scenario == 0 || scenario == 6) {
          point = {220, 240};
          Pointer(view, WM_POINTERUPDATE);
          point = {900, 900};
          Pointer(view, WM_POINTERDOWN, 8, POINTER_FLAG_INCONTACT);
          assert(sent.size() == (scenario == 6 ? 4u : 3u));
          assert(!GlobalSendDesktopTouchDragCancelled() || scenario == 6);
          Pointer(owner, WM_POINTERUP, 7, 0);
          assert(GlobalSendDesktopTouchDragStatus(FALSE) ==
              (scenario == 6 ? DRAGDROP_S_CANCEL : DRAGDROP_S_DROP));
        } else if (scenario == 1) {
          Pointer(view, WM_POINTERUPDATE, 7, POINTER_FLAG_CANCELED | POINTER_FLAG_PRIMARY);
          assert(GlobalSendDesktopTouchDragCancelled());
        } else if (scenario == 2) {
          SendMessageW(view, WM_POINTERCAPTURECHANGED, MAKEWPARAM(7, 0), 0);
          assert(GlobalSendDesktopTouchDragCancelled());
        } else if (scenario == 3) {
          AttachGlobalSendTouchDragWindow(dock, dock);
          DetachGlobalSendTouchDragWindow(dock);
          assert(!GlobalSendDesktopTouchDragCancelled());
          Pointer(view, WM_POINTERUP, 7, 0);
        } else if (scenario == 4) {
          throw std::runtime_error("mock OLE exception");
        } else if (scenario == 5) {
          GlobalSendDesktopForeignMouseForTest(WM_LBUTTONDOWN, sent.front().mi.dwExtraInfo);
          assert(!GlobalSendDesktopTouchDragCancelled());
          GlobalSendDesktopForeignMouseForTest(WM_LBUTTONDOWN);
          assert(GlobalSendDesktopTouchDragCancelled());
        } else if (scenario == 8) {
          GlobalSendDesktopForeignMouseForTest(WM_RBUTTONDOWN);
          assert(GlobalSendDesktopTouchDragCancelled());
        } else if (scenario == 10) {
          Pointer(view, WM_POINTERDOWN, 8); // A new primary contact cannot own this drag.
          assert(GlobalSendDesktopTouchDragCancelled());
        } else if (scenario == 15 || scenario == 16) {
          const ULONG_PTR marker = scenario == 15 ? 0xff515780 : 0xff515700;
          GlobalSendDesktopForeignMouseForTest(WM_RBUTTONDOWN, marker);
          GlobalSendDesktopForeignMouseForTest(WM_RBUTTONUP, marker);
          GlobalSendDesktopForeignMouseForTest(WM_LBUTTONUP, marker);
          assert(!GlobalSendDesktopTouchDragCancelled());
          Pointer(view, WM_POINTERUP, 7, 0);
        }
        *effect = DROPEFFECT_COPY;
        return scenario == 7 ? DRAGDROP_S_CANCEL : DRAGDROP_S_DROP;
      }, [&](bool did_copy, const std::string& failure) {
        std::cerr << "completed scenario " << scenario << ": " << failure << "\n";
        copied = did_copy; error = failure; finished = true;
      });
    Pump(finished);
    available = true;
    SetGlobalSendTouchPreparedForTest({});
    if (scenario == 9 || scenario == 12 || scenario == 13) {
      assert(runs == 0 && sent.empty() && !error.empty()); continue;
    }
    if (scenario == 11 || scenario == 14) {
      assert(runs == 0 && sent.size() == 1 && !copied);
      assert(error.empty() == (scenario == 14));
      continue;
    }
    assert(runs == 1);
    if (scenario == 5) assert(sent.size() == 2); // Never release another physical left press.
    else assert(sent.back().mi.dwFlags & MOUSEEVENTF_LEFTUP);
    assert(copied == (scenario == 0 || scenario == 3 || scenario == 15 || scenario == 16));
    assert(error.empty() == (scenario != 4 && scenario != 6));
    std::cerr << "mock touch adapter scenario " << scenario << " passed\n";
  }

  // The same adapter also uses the dock's own primary contact and source HWND.
  pointer_type = PT_TOUCH;
  sent.clear(); fail_down = foreign_on_down = fail_move = false;
  AttachGlobalSendTouchDragWindow(dock, dock);
  Pointer(dock, WM_POINTERDOWN, 60);
  bool dock_done = false;
  StartGlobalSendDesktopTouchDrag(L"dock", {}, dock,
      [&](HBITMAP bitmap, DWORD* effect) -> HRESULT {
        assert(bitmap);
        Pointer(dock, WM_POINTERUP, 60, 0);
        *effect = DROPEFFECT_COPY;
        return DRAGDROP_S_DROP;
      }, [&](bool copied, const std::string& error) {
        assert(copied && error.empty()); dock_done = true;
      });
  Pump(dock_done);
  assert(sent.size() == 3);
  DetachGlobalSendTouchDragWindow(dock);

  // Win11 promotion uses only Windows' move/up stream: no SendInput packets or
  // low-level mouse hook, and OLE's capture transition is not cancellation.
  for(int scenario=0;scenario<3;++scenario) {
    sent.clear();Pointer(view,WM_POINTERDOWN);
    SetGlobalSendPointerConversionForTest([scenario,view]() -> BOOL {
      SendMessageW(view,WM_POINTERCAPTURECHANGED,MAKEWPARAM(7,0),0);
      return scenario!=2;
    });
    bool finished=false;int runs=0;
    StartGlobalSendDesktopTouchDrag(L"native",{},owner,[&](HBITMAP bitmap,DWORD* effect) -> HRESULT {
      ++runs;assert(bitmap && sent.empty());
      for(int i=0;i<1000;++i)Pointer(view,WM_POINTERUPDATE);
      assert(sent.empty());assert(GlobalSendDesktopTouchDragStatus(FALSE,MK_LBUTTON)==S_OK);
      SendMessageW(view,WM_POINTERCAPTURECHANGED,MAKEWPARAM(7,0),0);
      SendMessageW(view,WM_POINTERLEAVE,MAKEWPARAM(7,0),0);
      assert(!GlobalSendDesktopTouchDragCancelled());
      if(scenario==1) {
        Pointer(view,WM_POINTERUPDATE,7,POINTER_FLAG_CANCELED|POINTER_FLAG_PRIMARY);
        assert(GlobalSendDesktopTouchDragStatus(FALSE,0)==DRAGDROP_S_CANCEL);
        return DRAGDROP_S_CANCEL;
      }
      Pointer(view,WM_POINTERUPDATE,7,POINTER_FLAG_PRIMARY);
      assert(!GlobalSendDesktopTouchDragCancelled());
      assert(GlobalSendDesktopTouchDragStatus(FALSE,0)==DRAGDROP_S_DROP);
      *effect=DROPEFFECT_COPY;return DRAGDROP_S_DROP;
    },[&](bool copied,const std::string& error) {
      assert(copied==(scenario==0));assert(error.empty()==(scenario!=2));finished=true;
    });
    Pump(finished);assert(runs==(scenario==2?0:1));assert(sent.empty());
  }
  SetGlobalSendPointerConversionForTest({});
  std::cerr << "native promotion: 1000 moves generate no synthetic input, capture handoff, release/drop and cancel passed\n";

  // Destruction while nested OLE is running releases only this adapter's press,
  // cancels the drag, and suppresses the dead engine's completion callback.
  sent.clear(); fail_move = false;
  Pointer(view, WM_POINTERDOWN);
  bool destroyed = false;
  StartGlobalSendDesktopTouchDrag(L"fixture", {}, owner,
      [&](HBITMAP, DWORD*) -> HRESULT {
        DestroyWindow(view);
        assert(GlobalSendDesktopTouchDragCancelled());
        assert(sent.size() == 3 && (sent.back().mi.dwFlags & MOUSEEVENTF_LEFTUP));
        destroyed = true;
        return DRAGDROP_S_CANCEL;
      }, [](bool, const std::string&) { assert(false); });
  Pump(destroyed);
  UnregisterGlobalSendTouchDrag();
  DestroyWindow(owner); DestroyWindow(dock);
  std::cout << "PASS: desktop touch adapter mock input/OLE, virtual coordinates, held contact generation, move/up/cancel/capture/exception, foreign mouse ownership and view lifetime\n";
  winrt::uninit_apartment();
}
