#include "../runner/receive_dock.h"
#include "../runner/touch_drag.h"
#include <cassert>
#include <iostream>

POINT location{123, 234};
UINT32 flags = POINTER_FLAG_PRIMARY | POINTER_FLAG_INCONTACT;
BOOL WINAPI Contact(UINT32 id, POINTER_INFO* info) {
  *info = {};
  info->pointerId = id; info->pointerType = PT_TOUCH;
  info->pointerFlags = flags; info->ptPixelLocation = location;
  return TRUE;
}
int main() {
  const RECT original{-100, 50, 380, 234};
  const POINT down{-90, 60}, current{-30, 65};
  const auto moved = GlobalSendReceiveDockMoveOrigin(original, down, current);
  assert(moved.x == -40 && moved.y == 55);
  const auto repeated = GlobalSendReceiveDockMoveOrigin(original, down, current);
  assert(repeated.x == moved.x && repeated.y == moved.y);
  HWND window = CreateWindowW(L"STATIC", L"Hidden move contact fixture", 0,
      0, 0, 100, 100, nullptr, nullptr, GetModuleHandleW(nullptr), nullptr);
  HWND other = CreateWindowW(L"STATIC", L"Other hidden fixture", 0,
      0, 0, 100, 100, nullptr, nullptr, GetModuleHandleW(nullptr), nullptr);
  assert(window && other);
  RegisterGlobalSendTouchDrag(window, window, Contact);
  SendMessageW(window, WM_POINTERDOWN, MAKEWPARAM(7, 0), 0);
  POINT point{};
  assert(GlobalSendHeldTouchPoint(window, &point) && point.x == 123 && point.y == 234);
  assert(!GlobalSendHeldTouchPoint(other, &point));
  location = {150, 260};
  SendMessageW(window, WM_POINTERUPDATE, MAKEWPARAM(7, 0), 0);
  assert(GlobalSendHeldTouchPoint(window, &point) && point.x == 150 && point.y == 260);
  SendMessageW(window, WM_POINTERUP, MAKEWPARAM(7, 0), 0);
  assert(!GlobalSendHeldTouchPoint(window, &point));
  UnregisterGlobalSendTouchDrag(); DestroyWindow(window); DestroyWindow(other);
  std::cout << "PASS anchored physical move, stable repeated point, held touch owner and END release\n";
}
