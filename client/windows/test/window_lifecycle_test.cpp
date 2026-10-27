#include "../runner/window_lifecycle.h"
#include <shellapi.h>
#include <cassert>
#include <iostream>
#include <memory>

std::unique_ptr<GlobalSendWindowLifecycle> lifecycle;
LRESULT CALLBACK WindowProc(HWND window, UINT message, WPARAM wp, LPARAM lp) {
  LRESULT result{};
  if (lifecycle && lifecycle->Handle(message, wp, lp, &result)) return result;
  return DefWindowProcW(window, message, wp, lp);
}

int main() {
  const RECT work{-1920, 40, 0, 1080};
  auto state = FitGlobalSendWindow({-9000, 9000, 950, 650, true}, work);
  assert(state.left == -1920 && state.top == 430 && state.width == 950);
  assert(state.maximized);
  state = FitGlobalSendWindow({0, 0, 5000, 5000, false}, RECT{0, 0, 800, 600});
  assert(state.width == 800 && state.height == 600 && state.left == 0 && state.top == 0);
  const RECT desktop{0, 0, 1920, 1080};
  assert(GlobalSendReceiptFullscreen(desktop, {}));
  assert(GlobalSendReceiptFullscreen(desktop, {{100, 100, 700, 600}}));
  assert(!GlobalSendReceiptFullscreen(desktop, {{0, 0, 1920, 1080}}));
  assert(!GlobalSendReceiptFullscreen(desktop, {{100, 100, 700, 600}, {800, 100, 1400, 600}}));

  WNDCLASSW cls{};
  cls.lpfnWndProc = WindowProc;
  cls.hInstance = GetModuleHandleW(nullptr);
  cls.lpszClassName = L"GlobalSendWindowLifecycleAcceptance";
  RegisterClassW(&cls);
  HWND window = CreateWindowW(cls.lpszClassName, L"GlobalSend lifecycle fixture",
      WS_OVERLAPPEDWINDOW, 10, 10, 950, 650, nullptr, nullptr, cls.hInstance, nullptr);
  assert(window);
  bool visible = true;
  int saves = 0;
  lifecycle = std::make_unique<GlobalSendWindowLifecycle>(window,
      [&](bool value) { visible = value; }, [&](const auto&) { ++saves; });
  // The HWND is hidden until Flutter draws. This is not a tray-hide request:
  // an early windowVisible query must keep MaterialApp mounted for that frame.
  assert(!IsWindowVisible(window));
  assert(lifecycle->Visible());
  lifecycle->ShowOnFirstFrame();
  assert(IsWindowVisible(window) && lifecycle->Visible() && visible);
  SendMessageW(window, WM_CLOSE, 0, 0);
  assert(!IsWindowVisible(window) && !lifecycle->Visible() && !visible);
  // A delayed first-frame callback cannot undo an explicit close-to-tray.
  lifecycle->ShowOnFirstFrame();
  assert(!IsWindowVisible(window) && !lifecycle->Visible() && !visible);
  const auto before_receipt = lifecycle->State();
  lifecycle->ShowReceived();
  assert(!IsWindowVisible(window) && !lifecycle->Visible() && !visible);
  const auto first_generation = lifecycle->ReceiptArrivalGeneration();
  assert(first_generation == 1);
  lifecycle->ShowReceived();
  const auto next_generation = lifecycle->ReceiptArrivalGeneration();
  assert(next_generation == first_generation + 1);
  RECT receipt_bounds{}, stale_bounds{};
  GetWindowRect(window, &receipt_bounds);
  lifecycle->DismissReceived(first_generation);
  GetWindowRect(window, &stale_bounds);
  assert(EqualRect(&receipt_bounds, &stale_bounds));
  const auto during_receipt = lifecycle->State();
  assert(during_receipt.width == before_receipt.width && during_receipt.height == before_receipt.height &&
         during_receipt.maximized == before_receipt.maximized);
  lifecycle->DismissReceived(next_generation);
  assert(lifecycle->State().width == before_receipt.width && lifecycle->State().height == before_receipt.height);
  ShowWindow(window, SW_MINIMIZE);
  const auto minimized_state = lifecycle->State();
  lifecycle->ShowReceived();
  assert(IsIconic(window));
  assert(lifecycle->State().width == minimized_state.width &&
      lifecycle->State().height == minimized_state.height);
  SendMessageW(window, WM_APP + 73, 0, MAKELPARAM(NIN_BALLOONUSERCLICK, 1));
  assert(IsWindowVisible(window) && lifecycle->Visible() && visible);
  lifecycle->Restore({20, 20, 950, 650, false});
  auto restored = lifecycle->State();
  assert(restored.width == 950 && restored.height == 650 && !restored.maximized);
  SendMessageW(window, WM_CLOSE, 0, 0);
  assert(IsWindow(window) && !lifecycle->Visible() && !visible && saves > 0);
  SendMessageW(window, WM_APP + 73, 0, MAKELPARAM(NIN_SELECT, 1));
  assert(lifecycle->Visible() && visible);
  lifecycle->Restore({20, 20, 950, 650, true});
  SendMessageW(window, WM_CLOSE, 0, 0);
  assert(lifecycle->State().maximized);
  SendMessageW(window, WM_APP + 73, 0, MAKELPARAM(NIN_SELECT, 1));
  assert(IsZoomed(window));
  lifecycle.reset();
  DestroyWindow(window);
  UnregisterClassW(cls.lpszClassName, cls.hInstance);
  std::cout << "PASS receipt generation and no main-window presentation mutation, startup-hidden UI intent, first-frame show, delayed-frame tray hide, bounds, restore, retained HWND, tray/maximize restore, cleanup\n";
}
