#include "../runner/auto_update.h"
#include <windows.h>
#include <cassert>
#include <filesystem>
#include <fstream>
#include <string>
#include <thread>
#include <chrono>
#include <winrt/base.h>

int wmain(int count, wchar_t** arguments) {
  assert(count == 2);
  winrt::init_apartment(winrt::apartment_type::multi_threaded);
  auto launch = GlobalSendUpdateLaunch::Start(std::filesystem::absolute(arguments[1]), "1.2.3", 400, nullptr, true);
  assert(launch->Running());
  launch->Cancel();
  for (int i = 0; i < 500 && launch->Running(); ++i)
    std::this_thread::sleep_for(std::chrono::milliseconds(10));
  assert(!launch->Running());
  std::ifstream receipt(launch->ResultPath());
  const std::string contents{std::istreambuf_iterator<char>(receipt), std::istreambuf_iterator<char>()};
  assert(contents.find("cancelled before extraction") != std::string::npos);
  const wchar_t* name = L"Local\\GlobalSend.UpdateFixture.Ready";
  const auto event = CreateEventW(nullptr, TRUE, FALSE, name);
  SetEnvironmentVariableW(L"GLOBALSEND_UPDATE_READY_EVENT", name);
  SignalGlobalSendUpdateReady();
  assert(WaitForSingleObject(event, 0) == WAIT_OBJECT_0);
  assert(GetEnvironmentVariableW(L"GLOBALSEND_UPDATE_READY_EVENT", nullptr, 0) == 0);
  CloseHandle(event);
  winrt::uninit_apartment();
  return 0;
}
