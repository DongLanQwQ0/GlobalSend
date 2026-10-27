#include "../runner/window_startup.h"
#include "../runner/win32_window.h"
#include <roapi.h>
#include <cassert>
#include <filesystem>
#include <fstream>
#include <iostream>

namespace fs = std::filesystem;
void Write(const fs::path& path, const std::string& text) {
  fs::create_directories(path.parent_path());
  std::ofstream(path, std::ios::binary) << text;
}

class ProbeWindow final : public Win32Window {
 public:
  RECT created{};
  RECT client{};
  bool visible_on_create = true;
  bool zoomed_on_create = false;
  int shows = 0;
 protected:
  bool OnCreate() override {
    GetWindowRect(GetHandle(), &created);
    client = GetClientArea();
    visible_on_create = IsWindowVisible(GetHandle()) != FALSE;
    zoomed_on_create = IsZoomed(GetHandle()) != FALSE;
    return true;
  }
  LRESULT MessageHandler(HWND window, UINT message, WPARAM wp, LPARAM lp) noexcept override {
    if (message == WM_SHOWWINDOW && wp) ++shows;
    return Win32Window::MessageHandler(window, message, wp, lp);
  }
};

int wmain(int argc, wchar_t** argv) {
  assert(argc == 2);
  const fs::path root = argv[1];
  fs::create_directories(root);
  const bool dpi_aware = SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2) != FALSE;
  assert(dpi_aware || AreDpiAwarenessContextsEqual(GetThreadDpiAwarenessContext(),
      DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2));
  const HRESULT initialized = RoInitialize(RO_INIT_SINGLETHREADED);
  assert(SUCCEEDED(initialized));
  wchar_t module[32768]{};
  assert(GetModuleFileNameW(nullptr, module, 32768));
  const fs::path executable = module;
  const fs::path install = root / L"install" / L"globalsend.exe";
  const fs::path roaming = root / L"roaming";
  fs::create_directories(install.parent_path());
  const auto override_path = root / L"override";
  assert(GlobalSendWindowStatePath(install, override_path.wstring(), roaming) ==
      override_path / L"window.json");
  Write(install.parent_path() / L"globalsend-data.json",
      "{\"dataDirectory\":\"" + (root / L"installed-data").generic_string() + "\"}");
  assert(GlobalSendWindowStatePath(install, L"", roaming) == root / L"installed-data" / L"window.json");
  assert(GlobalSendWindowStatePath(install, override_path.wstring(), roaming) == override_path / L"window.json");
  Write(install.parent_path() / L"globalsend-data.json",
      "{\"dataDirectory\":\"" + root.generic_string() + "/安装数据\"}");
  assert(GlobalSendWindowStatePath(install, L"", roaming) == root / L"安装数据" / L"window.json");
  Write(install.parent_path() / L"globalsend-data.json", "{broken");
  assert(GlobalSendWindowStatePath(install, L"", roaming).empty());
  // The test binary carries the same VERSIONINFO as the application.
  assert(GlobalSendWindowStatePath(executable, L"", roaming) ==
      roaming / L"dev.globalsend" / L"globalsend" / L"window.json");
  const auto state_path = override_path / L"window.json";
  assert(!ReadGlobalSendWindowState(state_path));
  Write(state_path, "{broken");
  assert(!ReadGlobalSendWindowState(state_path));
  Write(state_path, "{\"left\":40,\"top\":50,\"width\":950.25,\"maximized\":\"old\"}");
  const auto partial = ReadGlobalSendWindowState(state_path);
  assert(partial && partial->left == 40 && partial->top == 50 && partial->width == 950 &&
      partial->height == 650 && !partial->maximized);
  Write(state_path, "{\"left\":-1600,\"top\":80,\"width\":950,\"height\":650,\"maximized\":true}");
  auto saved = ReadGlobalSendWindowState(state_path);
  assert(saved && saved->left == -1600 && saved->top == 80 && saved->width == 950 &&
      saved->height == 650 && saved->maximized);
  const auto fitted = FitGlobalSendWindow(*saved, {-1920, 40, 0, 1080});
  assert(fitted.left == -1600 && fitted.top == 80 && fitted.width == 950 && fitted.maximized);
  SetEnvironmentVariableW(L"GLOBALSEND_DATA_DIR", override_path.c_str());
  const auto startup = LoadGlobalSendStartupWindow();
  assert(startup && startup->maximized);
  SetEnvironmentVariableW(L"GLOBALSEND_DATA_DIR", nullptr);
  std::cout << "PASS existing state source precedence, installed pointer, roaming VERSIONINFO, missing/bad JSON, saved negative bounds and load-before-create\n";

  ProbeWindow negative;
  const RECT exact{-1700, -120, -750, 530};
  assert(negative.CreateAtPhysicalBounds(L"GlobalSend hidden physical bounds", exact));
  assert(EqualRect(&negative.created, &exact));
  assert(!negative.visible_on_create && negative.shows == 0);
  std::cout << "PASS first native OnCreate sees exact physical negative coordinates, no DPI rescale or Show\n";
  negative.Destroy();

  ProbeWindow normal;
  const RECT actual{startup->left, startup->top, startup->left + startup->width,
      startup->top + startup->height};
  assert(normal.CreateAtPhysicalBounds(L"GlobalSend hidden saved normal", actual));
  assert(EqualRect(&normal.created, &actual));
  assert(!normal.visible_on_create && normal.shows == 0);
  normal.Destroy();

  ProbeWindow maximized;
  assert(maximized.CreateAtPhysicalBounds(L"GlobalSend hidden saved maximized", actual,
      WS_OVERLAPPEDWINDOW | WS_MAXIMIZE));
  assert(!maximized.visible_on_create && maximized.shows == 0 && maximized.zoomed_on_create);
  assert(maximized.client.right >= normal.client.right && maximized.client.bottom >= normal.client.bottom);
  WINDOWPLACEMENT placement{};
  placement.length = sizeof(placement);
  assert(GetWindowPlacement(maximized.GetHandle(), &placement));
  {
    GlobalSendWindowLifecycle lifecycle(maximized.GetHandle(), [](bool) {}, [](const auto&) {});
    const auto state = lifecycle.State();
    assert(state.maximized);
    assert(state.left == startup->left && state.top == startup->top &&
        state.width == startup->width && state.height == startup->height);
    assert(!IsWindowVisible(maximized.GetHandle()));
    assert(maximized.client.right > 0 && maximized.client.bottom > 0);
  }
  std::cout << "PASS hidden maximized creation has initial maximized client surface and preserved normal restore bounds before first-frame Show\n";
  maximized.Destroy();

  ProbeWindow initial;
  assert(initial.Create(L"GlobalSend hidden default", {10, 10}, {950, 650}));
  const UINT dpi = GetDpiForWindow(initial.GetHandle());
  assert(initial.created.right - initial.created.left == static_cast<int>(950 * dpi / 96.0));
  assert(initial.created.bottom - initial.created.top == static_cast<int>(650 * dpi / 96.0));
  assert(!initial.visible_on_create && initial.shows == 0);
  std::cout << "PASS no-state default retains 950x650 logical pixels and existing per-monitor DPI scaling\n";
  initial.Destroy();
  RoUninitialize();
}
