#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>
#include <roapi.h>

#include "flutter_window.h"
#include "utils.h"
#include "single_instance.h"
#include "window_startup.h"

int APIENTRY wWinMain(_In_ HINSTANCE, _In_opt_ HINSTANCE,
                      _In_ wchar_t *, _In_ int) {
  GlobalSendSingleInstance instance;
  const auto launch_paths = GlobalSendPathsFromCommandLine();
  const auto start = instance.AcquireOrActivate(30000, launch_paths);
  if (start == GlobalSendSingleInstance::Start::activated) return EXIT_SUCCESS;
  if (start == GlobalSendSingleInstance::Start::failed) {
    MessageBoxW(nullptr, L"GlobalSend 正在启动或暂时没有响应，请稍后再打开。",
                L"GlobalSend", MB_OK | MB_ICONINFORMATION);
    return EXIT_FAILURE;
  }
  QueueGlobalSendLaunchPaths(launch_paths);
  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  const HRESULT runtime = ::RoInitialize(RO_INIT_SINGLETHREADED);
  if (FAILED(runtime)) ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  // Resolve the existing state before creating a HWND or a Flutter surface.
  const auto startup_window = LoadGlobalSendStartupWindow();
  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(950, 650);
  const bool created = startup_window
      ? window.CreateAtPhysicalBounds(L"GlobalSend",
          {startup_window->left, startup_window->top,
           startup_window->left + startup_window->width,
           startup_window->top + startup_window->height},
          WS_OVERLAPPEDWINDOW | (startup_window->maximized ? WS_MAXIMIZE : 0))
      : window.Create(L"GlobalSend", origin, size);
  if (!created) {
    return EXIT_FAILURE;
  }
  if (!instance.AttachWindow(window.GetHandle())) return EXIT_FAILURE;
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  if (SUCCEEDED(runtime)) ::RoUninitialize();
  else ::CoUninitialize();
  return EXIT_SUCCESS;
}
