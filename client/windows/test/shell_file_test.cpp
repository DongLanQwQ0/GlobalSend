#include "../runner/shell_file.h"
#include <filesystem>
#include <fstream>
#include <iostream>
#include <vector>

namespace {
std::wstring expected;
int calls = 0;
bool valid_selection = true;
HRESULT WINAPI CheckSelection(PCIDLIST_ABSOLUTE item, UINT count,
    PCUITEMID_CHILD_ARRAY children, DWORD flags) {
  ++calls;
  PWSTR raw = nullptr;
  const HRESULT named = SHGetNameFromIDList(item, SIGDN_FILESYSPATH, &raw);
  valid_selection = valid_selection && count == 0 && children == nullptr && flags == 0 &&
      SUCCEEDED(named) && raw != nullptr && expected == raw;
  CoTaskMemFree(raw);
  return S_OK;
}
bool Check(bool value, const char* message) {
  if (!value) std::cerr << "FAIL: " << message << "\n";
  return value;
}
}

int wmain(int argc, wchar_t** argv) {
  if (argc < 2) return 2;
  // Match the production background worker's COM apartment.
  const HRESULT initialized = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
  if (FAILED(initialized)) return 2;
  const auto parent = std::filesystem::absolute(argv[1]);
  const auto root = parent / L"中文 空格,定位验收";
  const auto folder = root / L"文件夹 空格,子目录";
  std::filesystem::create_directories(folder);
  const auto plain = root / L"plain.txt";
  const auto named = root / L"中文 空格,逗号.txt";
  std::ofstream(plain) << "synthetic plain file";
  std::ofstream(named) << "synthetic unicode path file";
  bool passed = true;
  for (const auto& path : std::vector<std::filesystem::path>{plain, named, folder}) {
    expected = path.wstring();
    passed = Check(SUCCEEDED(RevealGlobalSendFile(expected, CheckSelection)), "existing item resolution") && passed;
  }
  const int before = calls;
  passed = Check(FAILED(RevealGlobalSendFile((root / L"不存在.txt").wstring(), CheckSelection)), "missing item fails") && passed;
  passed = Check(FAILED(RevealGlobalSendFile(L"", CheckSelection)), "empty path fails") && passed;
  passed = Check(calls == before && valid_selection, "exact complete PIDL; no open call for unavailable paths") && passed;
  if (argc >= 3) {
    const bool open_folder = std::wstring(argv[2]) == L"--open-folder";
    const auto selected = open_folder ? folder : named;
    const HRESULT opened = RevealGlobalSendFile(selected.wstring());
    std::cout << "Real shell open HRESULT: " << std::hex << static_cast<unsigned long>(opened) << "\n";
    passed = Check(SUCCEEDED(opened), "real shell opens selected item") && passed;
  }
  CoUninitialize();
  if (passed) std::cout << "PASS: file, Unicode/space/comma file, directory PIDLs; unavailable path never opens an unrelated folder\n";
  return passed ? 0 : 1;
}
