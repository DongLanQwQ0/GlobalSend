#include "single_instance.h"
#include <sddl.h>
#include <shellapi.h>
#include <utility>
#include <vector>

namespace {
constexpr ULONG_PTR kLaunchFiles = 0x47534631;
std::vector<std::vector<std::wstring>> pending_paths;
std::function<void(std::vector<std::wstring>)> launch_consumer;
bool launch_ready = false;
std::wstring CurrentUserSid() {
  HANDLE token = nullptr;
  if (!OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &token)) return {};
  DWORD size = 0;
  GetTokenInformation(token, TokenUser, nullptr, 0, &size);
  std::vector<BYTE> bytes(size);
  const BOOL read = GetTokenInformation(token, TokenUser, bytes.data(), size, &size);
  CloseHandle(token);
  if (!read) return {};
  auto* user = reinterpret_cast<TOKEN_USER*>(bytes.data());
  LPWSTR text = nullptr;
  if (!ConvertSidToStringSidW(user->User.Sid, &text)) return {};
  std::wstring result(text);
  LocalFree(text);
  return result;
}
}  // namespace

GlobalSendLaunchOptions ParseGlobalSendLaunchOptions(int count, const wchar_t* const* arguments) {
  GlobalSendLaunchOptions options;
  bool flags = true;
  for (int i = 1; i < count; ++i) {
    if (flags && std::wstring(arguments[i]) == L"--") { flags = false; continue; }
    if (flags && std::wstring(arguments[i]) == L"--background") { options.background = true; continue; }
    if (GetFileAttributesW(arguments[i]) == INVALID_FILE_ATTRIBUTES) continue;
    const DWORD length = GetFullPathNameW(arguments[i], 0, nullptr, nullptr);
    std::wstring path(length, L'\0');
    if (length && GetFullPathNameW(arguments[i], length, path.data(), nullptr)) {
      path.resize(wcslen(path.c_str()));
      options.paths.push_back(std::move(path));
    }
  }
  // Explicit files retain the existing open/import workflow, even when a
  // launcher appends the background-only startup flag.
  if (!options.paths.empty()) options.background = false;
  return options;
}
GlobalSendLaunchOptions GlobalSendLaunchFromCommandLine() {
  int count = 0;
  auto** arguments = CommandLineToArgvW(GetCommandLineW(), &count);
  auto options = arguments ? ParseGlobalSendLaunchOptions(count, arguments) : GlobalSendLaunchOptions{};
  if (arguments) LocalFree(arguments);
  return options;
}
std::vector<std::wstring> GlobalSendPathsFromCommandLine() {
  return GlobalSendLaunchFromCommandLine().paths;
}

void QueueGlobalSendLaunchPaths(std::vector<std::wstring> paths) {
  if (paths.empty()) return;
  if (launch_ready && launch_consumer) launch_consumer(std::move(paths));
  else pending_paths.push_back(std::move(paths));
}

void SetGlobalSendLaunchConsumer(
    std::function<void(std::vector<std::wstring>)> consumer) {
  launch_consumer = std::move(consumer);
  launch_ready = false;
}

void DrainGlobalSendLaunchFiles() {
  if (!launch_consumer) return;
  launch_ready = true;
  auto pending = std::move(pending_paths);
  pending_paths.clear();
  for (auto& paths : pending) launch_consumer(std::move(paths));
}

bool HandleGlobalSendLaunchMessage(UINT message, LPARAM parameter, LRESULT* result) {
  if (message != WM_COPYDATA) return false;
  const auto* data = reinterpret_cast<const COPYDATASTRUCT*>(parameter);
  if (!data || data->dwData != kLaunchFiles) return false;
  *result = 0;
  if (!data->lpData || data->cbData < sizeof(wchar_t) * 2 ||
      data->cbData % sizeof(wchar_t) != 0) return true;
  const auto* text = static_cast<const wchar_t*>(data->lpData);
  const size_t count = data->cbData / sizeof(wchar_t);
  if (text[count - 1] != L'\0' || text[count - 2] != L'\0') return true;
  std::vector<std::wstring> paths;
  for (size_t offset = 0; offset + 1 < count && text[offset];) {
    const size_t length = wcsnlen(text + offset, count - offset);
    if (length == count - offset) return true;
    paths.emplace_back(text + offset, length);
    offset += length + 1;
  }
  QueueGlobalSendLaunchPaths(std::move(paths));
  *result = 1;
  return true;
}
namespace {
struct Search {
  const wchar_t* property;
  HWND found = nullptr;
};
BOOL CALLBACK FindInstanceWindow(HWND window, LPARAM parameter) {
  auto& search = *reinterpret_cast<Search*>(parameter);
  if (GetPropW(window, search.property)) {
    search.found = window;
    return FALSE;
  }
  return TRUE;
}
}

UINT GlobalSendActivateMessage() {
  static const UINT message = RegisterWindowMessageW(L"GlobalSend.Activate.v1");
  return message;
}

GlobalSendSingleInstance::GlobalSendSingleInstance(const std::wstring& app) {
  const auto sid = CurrentUserSid();
  if (sid.empty()) return;
  window_property_ = app + L".InstanceWindow." + sid;
  const auto name = L"Local\\" + app + L".Instance." + sid;
  mutex_ = CreateMutexW(nullptr, FALSE, name.c_str());
}

GlobalSendSingleInstance::~GlobalSendSingleInstance() {
  if (window_ && IsWindow(window_)) RemovePropW(window_, window_property_.c_str());
  if (owned_) ReleaseMutex(mutex_);
  if (mutex_) CloseHandle(mutex_);
}

GlobalSendSingleInstance::Start GlobalSendSingleInstance::AcquireOrActivate(
    DWORD timeout_ms, const std::vector<std::wstring>& paths, bool activate) {
  if (!mutex_) return Start::failed;
  const ULONGLONG deadline = GetTickCount64() + timeout_ms;
  while (true) {
    const DWORD acquired = WaitForSingleObject(mutex_, 0);
    if (acquired == WAIT_OBJECT_0 || acquired == WAIT_ABANDONED) {
      owned_ = true;
      return Start::primary;
    }
    if (acquired != WAIT_TIMEOUT) return Start::failed;
    Search search{window_property_.c_str()};
    EnumWindows(FindInstanceWindow, reinterpret_cast<LPARAM>(&search));
    if (search.found) {
      DWORD process = 0;
      GetWindowThreadProcessId(search.found, &process);
      if (activate) AllowSetForegroundWindow(process);
      DWORD_PTR acknowledged = 0;
      if (!paths.empty()) {
        std::wstring packed;
        for (const auto& path : paths) { packed.append(path); packed.push_back(L'\0'); }
        packed.push_back(L'\0');
        COPYDATASTRUCT data{kLaunchFiles,
          static_cast<DWORD>(packed.size() * sizeof(wchar_t)), packed.data()};
        if (!SendMessageTimeoutW(search.found, WM_COPYDATA, 0,
              reinterpret_cast<LPARAM>(&data), SMTO_ABORTIFHUNG, 5000,
              &acknowledged) || acknowledged != 1) return Start::failed;
      }
      if (!activate) return Start::activated;
      if (SendMessageTimeoutW(search.found, GlobalSendActivateMessage(), 0, 0,
              SMTO_ABORTIFHUNG, 5000, &acknowledged) && acknowledged == 1) {
        return Start::activated;
      }
      return Start::failed;
    }
    // The first process may still be constructing its Flutter window. If it
    // exits meanwhile, a mutex acquisition (never a second concurrent owner)
    // makes this process the replacement primary.
    if (GetTickCount64() >= deadline) return Start::failed;
    Sleep(50);
  }
}

bool GlobalSendSingleInstance::AttachWindow(HWND window) {
  if (!owned_ || !SetPropW(window, window_property_.c_str(),
                           reinterpret_cast<HANDLE>(1))) return false;
  window_ = window;
  return true;
}
