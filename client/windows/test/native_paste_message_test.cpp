#include <windows.h>
#include <commctrl.h>
#include <winrt/Windows.Foundation.h>
#include <flutter/standard_method_codec.h>
#include <array>
#include <cassert>
#include <iostream>

std::array<SHORT, 256> paste_key_states{};
SHORT PasteTestKeyState(int key) { return paste_key_states[static_cast<size_t>(key)]; }
// Use the production dispatcher and subclass unchanged. Only keyboard-state
// sampling is supplied by this isolated message test, never desktop injection.
#define GetKeyState PasteTestKeyState
#include "../runner/system_integration.cpp"
#undef GetKeyState

class PasteMessenger final : public flutter::BinaryMessenger {
 public:
  mutable int requests = 0;
  void Send(const std::string& name, const uint8_t* data, size_t size,
      flutter::BinaryReply reply = nullptr) const override {
    assert(name == "dev.globalsend/system");
    const auto call = flutter::StandardMethodCodec::GetInstance().DecodeMethodCall(data, size);
    assert(call && call->method_name() == "pasteRequested");
    ++requests;
    if (reply) reply(nullptr, 0);
  }
  void SetMessageHandler(const std::string&, flutter::BinaryMessageHandler) override {}
};

int main() {
  PasteMessenger messenger;
  channel = std::make_unique<flutter::MethodChannel<Value>>(&messenger,
      "dev.globalsend/system", &flutter::StandardMethodCodec::GetInstance());
  const HWND view = CreateWindowExW(0, L"STATIC", L"GlobalSend hidden paste fixture",
      WS_POPUP, 0, 0, 200, 100, nullptr, nullptr, GetModuleHandleW(nullptr), nullptr);
  assert(view && !IsWindowVisible(view));
  assert(SetWindowSubclass(view, PasteSubclass, kPasteSubclass, 0));
  SendMessageW(view, WM_PASTE, 0, 0);
  assert(messenger.requests == 1);
  paste_key_states[VK_CONTROL] = static_cast<SHORT>(0x8000);
  SendMessageW(view, WM_KEYDOWN, 'V', 0);
  assert(messenger.requests == 2);
  SendMessageW(view, WM_CHAR, 0x16, 0);
  SendMessageW(view, WM_KEYUP, 'V', 0);
  assert(messenger.requests == 2 && !native_paste_key_down);
  paste_key_states[VK_SHIFT] = static_cast<SHORT>(0x8000);
  SendMessageW(view, WM_KEYDOWN, 'V', 0);
  assert(messenger.requests == 2);
  paste_key_states.fill(0);
  LRESULT result = -1;
  assert(HandleGlobalSendWindowMessage(WM_PASTE, 0, 0, &result));
  assert(result == 0 && messenger.requests == 3);
  SendMessageW(view, WM_PASTE, 0, 0);
  assert(messenger.requests == 4); // A separate explicit paste is not discarded.
  RemoveWindowSubclass(view, PasteSubclass, kPasteSubclass);
  DestroyWindow(view);
  channel.reset();
  std::cout << "PASS hidden child WM_PASTE and Ctrl+V, no CHAR/KEYUP duplicate, modifier preservation, parent ingress, repeated explicit paste\n";
}
