#include "flutter_window.h"
#include "system_integration.h"
#include "vault_dpapi.h"

#include <optional>
#include <wincrypt.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>
#pragma comment(lib, "Crypt32.lib")

#include "flutter/generated_plugin_registrant.h"

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  RegisterGlobalSendSystem(flutter_controller_->engine()->messenger(), GetHandle(),
                          flutter_controller_->view()->GetNativeWindow());
  flutter::MethodChannel<flutter::EncodableValue> vault(
      flutter_controller_->engine()->messenger(), "dev.globalsend/vault",
      &flutter::StandardMethodCodec::GetInstance());
  vault.SetMethodCallHandler([](const auto& call, auto result) {
    const auto* bytes = call.arguments() ? std::get_if<std::vector<uint8_t>>(call.arguments()) : nullptr;
    if (!bytes || (call.method_name() != "seal" && call.method_name() != "unseal")) {
      result->Error("BAD_ARGUMENT", "Expected protected byte operation"); return;
    }
    const bool seal = call.method_name() == "seal";
    auto output = GlobalSendVaultTransform(*bytes, seal);
    if (!output.ok) {
      const flutter::EncodableValue details(flutter::EncodableMap{
        {flutter::EncodableValue("operation"), flutter::EncodableValue(call.method_name())},
        {flutter::EncodableValue("windowsError"), flutter::EncodableValue(static_cast<int64_t>(output.windows_error))},
        {flutter::EncodableValue("scope"), flutter::EncodableValue("windowsCurrentUser")},
      });
      result->Error(seal ? "VAULT_SEAL_FAILED" : "VAULT_UNSEAL_FAILED",
                    seal ? "Windows could not protect credentials" : "Windows could not unlock protected credentials",
                    details);
      return;
    }
    flutter::EncodableValue value(std::move(output.bytes));
    result->Success(value);
    auto& delivered = std::get<std::vector<uint8_t>>(value);
    if (!delivered.empty()) SecureZeroMemory(delivered.data(), delivered.size());
  });
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  flutter_controller_->engine()->SetNextFrameCallback([]() {
    ShowGlobalSendWindowOnFirstFrame();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  UnregisterGlobalSendSystem();
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  LRESULT window_result = 0;
  if (HandleGlobalSendWindowMessage(message, wparam, lparam, &window_result)) {
    return window_result;
  }
  if (HandleGlobalSendMessage(message)) return 0;
  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
