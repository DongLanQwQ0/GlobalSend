#include "../runner/update_interaction.h"
#include <cassert>
#include <iostream>

int main() {
  GlobalSendUpdateExitGate exit;
  int ended = 0;
  GlobalSendUpdateInteraction* current = nullptr;
  GlobalSendUpdateInteraction interaction([&] {
    if (current->Busy()) exit.InteractionBegan(); else ++ended;
  });
  current = &interaction;
  const auto window = reinterpret_cast<HWND>(1);
  for (int reason = 0; reason < GlobalSendUpdateInteraction::count; ++reason) {
    exit.Request();
    interaction.Set(static_cast<GlobalSendUpdateInteraction::Reason>(reason), true);
    assert(interaction.Busy() && !exit.Prepare(interaction.Busy()));
    interaction.Set(static_cast<GlobalSendUpdateInteraction::Reason>(reason), false);
    assert(exit.Prepare(false));
    assert(exit.Resolve(true, false));
    assert(exit.Complete(false));
  }
  assert(ended == GlobalSendUpdateInteraction::count);
  interaction.Observe(window, WM_LBUTTONDOWN, 0);
  interaction.Set(GlobalSendUpdateInteraction::export_operation, true);
  interaction.Observe(window, WM_CAPTURECHANGED, 0);
  assert(interaction.Busy()); // Flutter retires its pointer; OLE still owns it.
  interaction.ReleasePointers();
  interaction.Set(GlobalSendUpdateInteraction::export_operation, false);
  assert(!interaction.Busy());
  interaction.Observe(window, WM_POINTERDOWN, 3);
  interaction.Observe(window, WM_POINTERDOWN, 4);
  interaction.Observe(window, WM_POINTERUP, 3);
  assert(interaction.Busy());
  interaction.Observe(window, WM_POINTERCAPTURECHANGED, 4);
  assert(!interaction.Busy());
  for (const auto messages : {std::pair{WM_ENTERSIZEMOVE, WM_EXITSIZEMOVE},
                             std::pair{WM_ENTERMENULOOP, WM_EXITMENULOOP}}) {
    interaction.Observe(window, messages.first, 0); assert(interaction.Busy());
    interaction.Observe(window, messages.second, 0); assert(!interaction.Busy());
  }
  exit.Request(); assert(exit.Prepare(false));
  interaction.Set(GlobalSendUpdateInteraction::drop_hover, true);
  interaction.Set(GlobalSendUpdateInteraction::drop_hover, false);
  assert(!exit.Resolve(true, false) && exit.FreshCheckNeeded());
  assert(exit.Prepare(false) && exit.Resolve(true, false));
  // A new gesture can begin and end after Dart approval, before the posted exit.
  interaction.Observe(window, WM_RBUTTONDOWN, 0);
  interaction.Observe(window, WM_RBUTTONUP, 0);
  assert(!exit.Complete(false));
  assert(exit.Prepare(false) && exit.Resolve(true, false));
  exit.Cancel(); assert(!exit.Complete(false));
  assert(!exit.Requested());
  std::cout << "PASS: OLE/preparation, incoming hover, move/resize, menu, pointers, stale approval and cancellation\n";
}
