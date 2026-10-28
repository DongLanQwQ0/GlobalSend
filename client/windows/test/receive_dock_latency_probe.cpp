#include "../runner/receive_dock.h"
#include <flutter/encodable_value.h>
#include <iostream>
#include <functional>

namespace {
using Value = flutter::EncodableValue;
using Map = flutter::EncodableMap;
bool PumpUntil(const std::function<bool()>& done, ULONGLONG limit_ms) {
  const auto start = GetTickCount64();
  while (!done() && GetTickCount64() - start < limit_ms) {
    MSG message{};
    while (PeekMessageW(&message, nullptr, 0, 0, PM_REMOVE)) {
      TranslateMessage(&message);
      DispatchMessageW(&message);
    }
    Sleep(5);
  }
  return done();
}
Map Content(int64_t generation, const char* id) {
  return {{Value("arrivalGeneration"), Value(generation)},
    {Value("serial"), Value(generation)},
    {Value("items"), Value(flutter::EncodableList{Value(Map{
      {Value("id"), Value(id)}, {Value("kind"), Value("text")},
      {Value("title"), Value("latency fixture")}, {Value("source"), Value("fixture")},
      {Value("status"), Value("ready")},
      {Value("text"), Value("Receive dock latency fixture")}
    })})}};
}
}

// No input injection, network session, credentials, main window or tray.
// Uses the existing release's display-only Dart entrypoint and current C++ dock.
int main() {
  OleInitialize(nullptr);
  SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
  int presentations = 0;
  const auto start = GetTickCount64();
  GlobalSendReceiveDock dock(Map{{Value("items"), Value(flutter::EncodableList{})}},
    [](const Map&) {}, {}, [&] { ++presentations; }, [](int64_t) {});
  if (!dock.Open() || !PumpUntil([&] { return dock.Ready(); }, 15000)) return 2;
  const auto warm_ms = GetTickCount64() - start;
  if (dock.Shown() || IsWindowVisible(dock.GetHandle())) return 3;
  const HWND original_window = dock.GetHandle();
  const auto first = GetTickCount64();
  dock.Update(Content(1, "one"));
  if (!PumpUntil([&] { return presentations == 1; }, 3000)) return 4;
  const auto first_ms = GetTickCount64() - first;
  // Finish entrance before closing. Closing retains the engine, not content.
  const auto slide = GetTickCount64();
  PumpUntil([&] { return GetTickCount64() - slide >= 350; }, 1000);
  dock.HideAnimated();
  if (!PumpUntil([&] { return dock.ClosingFinished(); }, 1000)) return 5;
  dock.ClearContent();
  if (IsWindowVisible(original_window)) return 6;
  const auto next = GetTickCount64();
  dock.Update(Content(2, "two"));
  if (!PumpUntil([&] { return presentations == 2; }, 3000)) return 7;
  const auto reused_ms = GetTickCount64() - next;
  if (dock.GetHandle() != original_window) return 8;
  std::cout << "{\"warmupMs\":" << warm_ms << ",\"firstContentFrameMs\":" << first_ms
      << ",\"reusedContentFrameMs\":" << reused_ms
      << ",\"sameWindow\":true,\"emptyWarmupHidden\":true}" << std::endl;
  dock.HideAnimated();
  PumpUntil([&] { return dock.ClosingFinished(); }, 1000);
  return first_ms < 1000 && reused_ms < 1000 ? 0 : 9;
}
