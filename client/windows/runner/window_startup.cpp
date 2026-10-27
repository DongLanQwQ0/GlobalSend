#include "window_startup.h"

#include <shlobj.h>
#include <winrt/Windows.Data.Json.h>
#include <winrt/Windows.Foundation.Collections.h>
#include <cmath>
#include <fstream>
#include <iterator>
#include <limits>
#include <vector>

namespace {
using winrt::Windows::Data::Json::JsonObject;

std::string ReadText(const std::filesystem::path& path) {
  std::ifstream file(path, std::ios::binary);
  return {std::istreambuf_iterator<char>(file), std::istreambuf_iterator<char>()};
}

std::wstring Environment(const wchar_t* name) {
  const DWORD size = GetEnvironmentVariableW(name, nullptr, 0);
  if (!size) return {};
  std::wstring value(size, L'\0');
  value.resize(GetEnvironmentVariableW(name, value.data(), size));
  return value;
}

std::wstring VersionString(const std::vector<BYTE>& version, const wchar_t* key) {
  for (const auto* encoding : {L"040904e4", L"040904b0"}) {
    const auto query = std::wstring(L"\\StringFileInfo\\") + encoding + L"\\" + key;
    wchar_t* value = nullptr;
    UINT length = 0;
    if (VerQueryValueW(version.data(), query.c_str(),
        reinterpret_cast<void**>(&value), &length) && length > 1) return value;
  }
  return {};
}

std::wstring DirectoryComponent(std::wstring value) {
  for (auto& ch : value) {
    if (std::wstring_view(L"<>:\"/\\|?*").find(ch) != std::wstring_view::npos) ch = L'_';
  }
  while (!value.empty() && iswspace(value.back())) value.pop_back();
  while (!value.empty() && value.back() == L'.') value.pop_back();
  if (value.size() > 255) value.resize(255);
  return value;
}
}

std::filesystem::path GlobalSendWindowStatePath(
    const std::filesystem::path& executable, const std::wstring& data_override,
    const std::filesystem::path& roaming) {
  if (!data_override.empty()) return std::filesystem::path(data_override) / L"window.json";
  const auto installed = executable.parent_path() / L"globalsend-data.json";
  if (std::filesystem::exists(installed)) {
    try {
      const auto pointer = JsonObject::Parse(winrt::to_hstring(ReadText(installed)));
      const auto path = pointer.GetNamedString(L"dataDirectory");
      return path.empty() ? std::filesystem::path{} : std::filesystem::path(path.c_str()) / L"window.json";
    } catch (const winrt::hresult_error&) {
      // The main UI retains responsibility for reporting a bad installation
      // pointer. Do not read another identity's roaming state instead.
      return {};
    }
  }
  DWORD unused = 0;
  std::vector<BYTE> version(GetFileVersionInfoSizeW(executable.c_str(), &unused));
  std::wstring company, product;
  if (!version.empty() && GetFileVersionInfoW(executable.c_str(), 0,
      static_cast<DWORD>(version.size()), version.data())) {
    company = DirectoryComponent(VersionString(version, L"CompanyName"));
    product = DirectoryComponent(VersionString(version, L"ProductName"));
  }
  if (product.empty()) product = executable.stem().wstring();
  if (roaming.empty()) return {};
  return roaming / company / product / L"window.json";
}

std::optional<GlobalSendWindowState> ReadGlobalSendWindowState(
    const std::filesystem::path& path) {
  if (path.empty()) return std::nullopt;
  const auto text = ReadText(path);
  if (text.empty()) return std::nullopt;
  try {
    const auto value = JsonObject::Parse(winrt::to_hstring(text));
    auto integer = [&](const wchar_t* key, int fallback) {
      if (!value.HasKey(key) || value.Lookup(key).ValueType() !=
          winrt::Windows::Data::Json::JsonValueType::Number) return fallback;
      const double number = value.GetNamedNumber(key);
      if (std::floor(number) != number || number < std::numeric_limits<int>::min() ||
          number > std::numeric_limits<int>::max()) return fallback;
      return static_cast<int>(number);
    };
    const bool maximized = value.HasKey(L"maximized") &&
        value.Lookup(L"maximized").ValueType() == winrt::Windows::Data::Json::JsonValueType::Boolean &&
        value.GetNamedBoolean(L"maximized");
    return GlobalSendWindowState{integer(L"left", 10), integer(L"top", 10), integer(L"width", 950),
        integer(L"height", 650), maximized};
  } catch (const winrt::hresult_error&) {
    return std::nullopt;
  }
}

std::optional<GlobalSendWindowState> LoadGlobalSendStartupWindow() {
  std::wstring executable(32768, L'\0');
  executable.resize(GetModuleFileNameW(nullptr, executable.data(),
      static_cast<DWORD>(executable.size())));
  PWSTR folder = nullptr;
  std::filesystem::path roaming;
  if (SUCCEEDED(SHGetKnownFolderPath(FOLDERID_RoamingAppData, KF_FLAG_DEFAULT,
      nullptr, &folder))) {
    roaming = folder;
    CoTaskMemFree(folder);
  }
  const auto path = GlobalSendWindowStatePath(executable,
      Environment(L"GLOBALSEND_DATA_DIR"), roaming);
  auto state = ReadGlobalSendWindowState(path);
  if (state) {
    RECT bounds{state->left, state->top, state->left + state->width,
        state->top + state->height};
    MONITORINFO monitor{sizeof(monitor)};
    if (GetMonitorInfoW(MonitorFromRect(&bounds, MONITOR_DEFAULTTONEAREST), &monitor)) {
      *state = FitGlobalSendWindow(*state, monitor.rcWork);
    }
  }
  return state;
}
