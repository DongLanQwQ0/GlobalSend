#include "autostart.h"
#include <windows.h>
#include <shellapi.h>
#include <system_error>

namespace {
constexpr auto kRunKey = L"Software\\Microsoft\\Windows\\CurrentVersion\\Run";
constexpr auto kValue = L"GlobalSend";

void Check(LSTATUS status) {
  if (status != ERROR_SUCCESS) throw std::system_error(status, std::system_category());
}
std::wstring Executable() {
  std::wstring path(32768, L'\0');
  const DWORD length = GetModuleFileNameW(nullptr, path.data(), static_cast<DWORD>(path.size()));
  if (!length || length >= path.size()) throw std::system_error(GetLastError(), std::system_category());
  path.resize(length);
  return path;
}
}

std::wstring GlobalSendAutoStartCommand(const std::wstring& executable) {
  return L"\"" + executable + L"\" --background";
}

bool GlobalSendAutoStartEnabled() {
  constexpr DWORD types = RRF_RT_REG_SZ | RRF_RT_REG_EXPAND_SZ;
  DWORD bytes = 0;
  auto status = RegGetValueW(HKEY_CURRENT_USER, kRunKey, kValue, types, nullptr, nullptr, &bytes);
  if (status == ERROR_FILE_NOT_FOUND) return false;
  Check(status);
  std::wstring command((bytes + sizeof(wchar_t) - 1) / sizeof(wchar_t), L'\0');
  Check(RegGetValueW(HKEY_CURRENT_USER, kRunKey, kValue, types, nullptr, command.data(), &bytes));
  int count = 0;
  auto** arguments = CommandLineToArgvW(command.c_str(), &count);
  const bool enabled = arguments && count == 2 &&
      _wcsicmp(arguments[0], Executable().c_str()) == 0 && std::wstring(arguments[1]) == L"--background";
  if (arguments) LocalFree(arguments);
  return enabled;
}

void SetGlobalSendAutoStart(bool enabled) {
  const auto command = GlobalSendAutoStartCommand(Executable());
  if (enabled && command.size() > 260) throw std::system_error(ERROR_FILENAME_EXCED_RANGE, std::system_category());
  HKEY key = nullptr;
  auto status = enabled
      ? RegCreateKeyExW(HKEY_CURRENT_USER, kRunKey, 0, nullptr, 0, KEY_SET_VALUE, nullptr, &key, nullptr)
      : RegOpenKeyExW(HKEY_CURRENT_USER, kRunKey, 0, KEY_SET_VALUE, &key);
  if (!enabled && status == ERROR_FILE_NOT_FOUND) return;
  Check(status);
  status = enabled ? RegSetValueExW(key, kValue, 0, REG_SZ,
      reinterpret_cast<const BYTE*>(command.c_str()), static_cast<DWORD>((command.size() + 1) * sizeof(wchar_t)))
      : RegDeleteValueW(key, kValue);
  RegCloseKey(key);
  if (!enabled && status == ERROR_FILE_NOT_FOUND) return;
  Check(status);
}
