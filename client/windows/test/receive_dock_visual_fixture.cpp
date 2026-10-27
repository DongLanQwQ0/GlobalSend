#include "../runner/receive_dock.h"
#include <windows.h>
#include <ole2.h>
#include <commctrl.h>
#include <iostream>

using V = flutter::EncodableValue;
using M = flutter::EncodableMap;
std::unique_ptr<GlobalSendReceiveDock> dock;
void TraceMotion(UINT_PTR id) {
  SetTimer(dock->GetHandle(), id, 30, [](HWND window, UINT, UINT_PTR timer, DWORD) {
    static int enter_samples = 0, exit_samples = 0;
    auto& samples = timer == 93 ? enter_samples : exit_samples;
    RECT r{}; GetWindowRect(dock->GetHandle(), &r);
    std::cout << (timer == 93 ? "ENTER " : "EXIT ") << GetTickCount64()
        << " x=" << r.left << " visible=" << IsWindowVisible(dock->GetHandle()) << "\n" << std::flush;
    if (++samples >= 12) KillTimer(window, timer);
  });
}
M Payload(int count) {
  flutter::EncodableList items;
  for (int i = 0; i < count; ++i) {
    items.emplace_back(M{{V("id"), V(std::to_string(i))}, {V("kind"), V("text")},
      {V("title"), V("文本")}, {V("text"), V(i == 0 ? "这是一段接收文本。整张卡片可以拖出。" : "新收到的内容")},
      {V("source"), V("fixture")}, {V("status"), V("received")}, {V("sender"), V("测试设备")},
      {V("receivedAtMillis"), V(int64_t(1793028000000LL))}});
  }
  return {{V("serial"), V(count)}, {V("arrivalGeneration"), V(count)}, {V("items"), V(items)}};
}
int main() {
  OleInitialize(nullptr);
  dock = std::make_unique<GlobalSendReceiveDock>(Payload(2), [](const M& values) {
      const auto action = values.find(V("action"));
      if (action != values.end() && std::get<std::string>(action->second) == "close") dock->HideAnimated();
    }, [](const M&, auto completion, HWND) { completion->Success(V(false)); },
    [] { std::cout << "PRESENTED\n" << std::flush; TraceMotion(93); },
    [](int64_t) { std::cout << "CLOSED visible=" << IsWindowVisible(dock->GetHandle()) << "\n" << std::flush; PostQuitMessage(0); });
  if (!dock->Open()) return 2;
  // Expose only this fixture in the task switcher so standard UI automation can
  // select its returned Window. Production retains WS_EX_TOOLWINDOW.
  SetWindowLongPtrW(dock->GetHandle(), GWL_EXSTYLE,
      (GetWindowLongPtrW(dock->GetHandle(), GWL_EXSTYLE) & ~WS_EX_TOOLWINDOW) | WS_EX_APPWINDOW);
  SetWindowSubclass(dock->GetHandle(), [](HWND window, UINT message, WPARAM wp, LPARAM lp, UINT_PTR, DWORD_PTR) -> LRESULT {
    if (message == WM_SYSCOMMAND || message == WM_ENTERSIZEMOVE || message == WM_EXITSIZEMOVE) {
      RECT r{}; GetWindowRect(window, &r);
      std::cout << "MOVE_EVENT " << message << " wp=" << wp << " x=" << r.left << " y=" << r.top << "\n" << std::flush;
    }
    return DefSubclassProc(window, message, wp, lp);
  }, 0x47534656, 0);
  SetTimer(nullptr, 91, 5500, [](HWND, UINT, UINT_PTR id, DWORD) {
    KillTimer(nullptr, id);
    dock->Update(Payload(6));
    RECT r{}; GetWindowRect(dock->GetHandle(), &r);
    std::cout << "UPDATED " << r.right-r.left << "x" << r.bottom-r.top << "\n" << std::flush;
    HRGN region = CreateRectRgn(0, 0, 0, 0);
    const auto type = GetWindowRgn(dock->GetHandle(), region);
    std::cout << "REGION type=" << type << " blank=" << PtInRegion(region, 310, 15)
        << " card=" << PtInRegion(region, 50, 80) << "\n" << std::flush;
    DeleteObject(region);
  });
  SetTimer(nullptr, 92, 180000, [](HWND, UINT, UINT_PTR id, DWORD) {
    KillTimer(nullptr, id); TraceMotion(94); dock->HideAnimated();
  });
  SetTimer(nullptr, 95, 200, [](HWND, UINT, UINT_PTR, DWORD) {
    HRGN region = CreateRectRgn(0, 0, 0, 0);
    GetWindowRgn(dock->GetHandle(), region);
    const auto bytes = GetRegionData(region, 0, nullptr);
    std::vector<BYTE> buffer(bytes);
    if (bytes && GetRegionData(region, bytes, reinterpret_cast<RGNDATA*>(buffer.data()))) {
      const auto* data = reinterpret_cast<const RGNDATA*>(buffer.data());
      const auto* rects = reinterpret_cast<const RECT*>(data->Buffer);
      std::string snapshot;
      for (DWORD i = 0; i < data->rdh.nCount; ++i) {
        snapshot += std::to_string(rects[i].left) + "," + std::to_string(rects[i].top) + ","
            + std::to_string(rects[i].right) + "," + std::to_string(rects[i].bottom) + ";";
      }
      static std::string previous;
      if (snapshot != previous) {
        previous = snapshot;
        std::cout << "APPLIED_REGION " << GetTickCount64() << " " << snapshot << "\n" << std::flush;
      }
    }
    DeleteObject(region);
  });
  MSG message{};
  while (GetMessageW(&message, nullptr, 0, 0)) {
    TranslateMessage(&message); DispatchMessageW(&message);
  }
  dock.reset(); OleUninitialize();
}
