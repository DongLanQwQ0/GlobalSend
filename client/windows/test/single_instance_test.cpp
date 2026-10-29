#include "../runner/single_instance.h"
#include "../runner/window_lifecycle.h"
#include <cassert>
#include <iostream>
#include <memory>
#include <string>

std::unique_ptr<GlobalSendWindowLifecycle> lifecycle;
LRESULT CALLBACK WindowProc(HWND window, UINT message, WPARAM wp, LPARAM lp) {
  LRESULT result{};
  if (lifecycle && lifecycle->Handle(message, wp, lp, &result)) return result;
  return DefWindowProcW(window, message, wp, lp);
}

PROCESS_INFORMATION Spawn(const std::wstring& arguments) {
  wchar_t executable[32768]{};
  GetModuleFileNameW(nullptr, executable, 32768);
  std::wstring command = L"\"" + std::wstring(executable) + L"\" " + arguments;
  STARTUPINFOW startup{};
  startup.cb = sizeof(startup);
  PROCESS_INFORMATION process{};
  assert(CreateProcessW(nullptr, command.data(), nullptr, nullptr, FALSE,
                        CREATE_NO_WINDOW, nullptr, nullptr, &startup, &process));
  CloseHandle(process.hThread);
  return process;
}

DWORD WaitWithMessages(HANDLE process) {
  const auto end = GetTickCount64() + 10000;
  while (WaitForSingleObject(process, 0) != WAIT_OBJECT_0) {
    MSG message{};
    while (PeekMessageW(&message, nullptr, 0, 0, PM_REMOVE)) {
      TranslateMessage(&message);
      DispatchMessageW(&message);
    }
    assert(GetTickCount64() < end);
    Sleep(5);
  }
  DWORD code = 0;
  assert(GetExitCodeProcess(process, &code));
  CloseHandle(process);
  return code;
}

int wmain(int argc, wchar_t** argv) {
  if (argc >= 3 && std::wstring(argv[1]) == L"--activate") {
    GlobalSendSingleInstance instance(argv[2]);
    const auto start = instance.AcquireOrActivate(5000);
    return start == GlobalSendSingleInstance::Start::activated ? 0 : 40;
  }
  if (argc >= 3 && std::wstring(argv[1]) == L"--background-duplicate") {
    GlobalSendSingleInstance instance(argv[2]);
    return instance.AcquireOrActivate(5000, {}, false) == GlobalSendSingleInstance::Start::activated ? 0 : 44;
  }
  if (argc >= 4 && std::wstring(argv[1]) == L"--hold") {
    GlobalSendSingleInstance instance(argv[2]);
    if (instance.AcquireOrActivate() != GlobalSendSingleInstance::Start::primary) return 41;
    HANDLE ready = OpenEventW(EVENT_MODIFY_STATE, FALSE, argv[3]);
    if (!ready) return 42;
    SetEvent(ready);
    CloseHandle(ready);
    Sleep(INFINITE);
    return 43;
  }

  WNDCLASSW cls{};
  cls.lpfnWndProc = WindowProc;
  cls.hInstance = GetModuleHandleW(nullptr);
  cls.lpszClassName = L"GlobalSendSingleInstanceFixture";
  RegisterClassW(&cls);
  const std::wstring id = L"GlobalSend.InstanceFixture." + std::to_wstring(GetCurrentProcessId());
  {
    GlobalSendSingleInstance primary(id);
    assert(primary.AcquireOrActivate() == GlobalSendSingleInstance::Start::primary);
    auto early = Spawn(L"--activate " + id);
    Sleep(250); // Duplicate arrives before the first window exists.
    assert(WaitForSingleObject(early.hProcess, 0) == WAIT_TIMEOUT);
    HWND window = CreateWindowW(cls.lpszClassName, L"GlobalSend single-instance fixture",
        WS_OVERLAPPEDWINDOW, 10, 10, 950, 650, nullptr, nullptr, cls.hInstance, nullptr);
    assert(window);
    bool visible = false;
    int restores = 0;
    lifecycle = std::make_unique<GlobalSendWindowLifecycle>(window,
        [&](bool value) { visible = value; if (value) ++restores; }, [](const auto&) {});
    assert(primary.AttachWindow(window));
    assert(WaitWithMessages(early.hProcess) == 0);
    assert(IsWindowVisible(window) && visible && restores == 1);

    SendMessageW(window, WM_CLOSE, 0, 0);
    assert(IsWindow(window) && !IsWindowVisible(window) && !visible);
    auto quiet = Spawn(L"--background-duplicate " + id);
    assert(WaitWithMessages(quiet.hProcess) == 0);
    assert(!IsWindowVisible(window) && !visible && restores == 1);
    auto tray = Spawn(L"--activate " + id);
    assert(WaitWithMessages(tray.hProcess) == 0);
    assert(IsWindowVisible(window) && visible && restores == 2);

    ShowWindow(window, SW_MINIMIZE);
    assert(IsIconic(window));
    auto minimized = Spawn(L"--activate " + id);
    assert(WaitWithMessages(minimized.hProcess) == 0);
    assert(IsWindowVisible(window) && !IsIconic(window) && restores == 3);
    lifecycle.reset();
    DestroyWindow(window);
  }
  {
    GlobalSendSingleInstance reopened(id);
    assert(reopened.AcquireOrActivate() == GlobalSendSingleInstance::Start::primary);
  }
  {
    const auto crash_id = id + L".Crash";
    const auto ready_name = L"Local\\" + id + L".Ready";
    HANDLE ready = CreateEventW(nullptr, TRUE, FALSE, ready_name.c_str());
    auto holder = Spawn(L"--hold " + crash_id + L" " + ready_name);
    assert(WaitForSingleObject(ready, 5000) == WAIT_OBJECT_0);
    GlobalSendSingleInstance replacement(crash_id); // Keep the kernel object alive.
    assert(TerminateProcess(holder.hProcess, 0)); // Only the fixture's own child.
    assert(WaitForSingleObject(holder.hProcess, 5000) == WAIT_OBJECT_0);
    CloseHandle(holder.hProcess);
    CloseHandle(ready);
    assert(replacement.AcquireOrActivate() == GlobalSendSingleInstance::Start::primary);
  }
  UnregisterClassW(cls.lpszClassName, cls.hInstance);
  std::cout << "PASS startup race, duplicate-process exit, tray/minimized restore, normal exit and abandoned-mutex recovery\n";
}
