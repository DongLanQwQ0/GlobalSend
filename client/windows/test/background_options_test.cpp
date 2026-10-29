#include "../runner/single_instance.h"
#include "../runner/autostart.h"
#include <cassert>
#include <filesystem>
#include <fstream>
#include <iostream>

// Pass a project-local artifact directory; no HWNDs or registry writes.
int wmain(int argc, wchar_t** argv) {
  assert(argc == 2);
  const auto folder = std::filesystem::path(argv[1]) / std::to_wstring(GetCurrentProcessId());
  std::filesystem::create_directories(folder);
  const auto file = folder / L"测试 file.txt";
  std::ofstream(file) << "fixture";
  const std::wstring path = file.wstring();
  const wchar_t* background[] = {L"GlobalSend.exe", L"--background"};
  auto launch = ParseGlobalSendLaunchOptions(2, background);
  assert(launch.background && launch.paths.empty());
  const wchar_t* files[] = {L"GlobalSend.exe", L"files", path.c_str(), L"--background"};
  launch = ParseGlobalSendLaunchOptions(4, files);
  assert(!launch.background && launch.paths.size() == 1);
  assert(std::filesystem::path(launch.paths[0]) == std::filesystem::absolute(file));
  const auto literal = folder / L"--background";
  std::ofstream(literal) << "fixture";
  const auto before = std::filesystem::current_path();
  std::filesystem::current_path(folder);
  const wchar_t* escaped[] = {L"GlobalSend.exe", L"--", L"--background"};
  launch = ParseGlobalSendLaunchOptions(3, escaped);
  std::filesystem::current_path(before);
  assert(!launch.background && launch.paths.size() == 1);
  assert(GlobalSendAutoStartCommand(L"F:\\目录 空格\\GlobalSend.exe") ==
      L"\"F:\\目录 空格\\GlobalSend.exe\" --background");
  std::filesystem::remove(file);std::filesystem::remove(literal);std::filesystem::remove(folder);
  std::cout << "PASS background-only flags, existing file entry, literal flag filename and quoted startup command\n";
}
