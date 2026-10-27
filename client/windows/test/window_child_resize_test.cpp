#include "../runner/win32_window.h"
#include <cassert>
#include <iostream>

class HiddenWindow final : public Win32Window {
 public:
  HWND child = nullptr;
 protected:
  bool OnCreate() override {
    child = CreateWindowExW(0, L"STATIC", L"", WS_CHILD, 0, 0, 20, 20,
        GetHandle(), nullptr, GetModuleHandleW(nullptr), nullptr);
    SetChildContent(child, false);
    return child != nullptr;
  }
};

int main() {
  HiddenWindow window;
  assert(window.Create(L"GlobalSend hidden resize fixture", {0, 0}, {480, 184}, WS_POPUP));
  assert(!(GetWindowLongPtrW(window.GetHandle(), GWL_STYLE) & WS_CAPTION));
  for (const SIZE size : {SIZE{480, 184}, SIZE{640, 240}, SIZE{480, 184}}) {
    SetWindowPos(window.GetHandle(), nullptr, 0, 0, size.cx, size.cy,
        SWP_NOZORDER | SWP_NOACTIVATE);
    SendMessageW(window.GetHandle(), WM_SIZE, SIZE_RESTORED, MAKELPARAM(size.cx, size.cy));
    RECT client{}, child{};
    GetClientRect(window.GetHandle(), &client);
    GetClientRect(window.child, &child);
    assert(EqualRect(&client, &child));
    assert(!IsWindowVisible(window.GetHandle()));
  }
  std::cout << "PASS popup starts without caption; SIZE_RESTORED resizes child on each update without showing window\n";
}
