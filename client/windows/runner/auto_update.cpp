#include "auto_update.h"
#include <winrt/Windows.Data.Json.h>
#include <fstream>
#include <system_error>
#include <vector>

namespace {
std::wstring Quote(const std::wstring& value) {
  std::wstring result = L"\"";
  size_t slashes = 0;
  for (const wchar_t ch : value) {
    if (ch == L'\\') { ++slashes; continue; }
    result.append(slashes * (ch == L'\"' ? 2 : 1), L'\\');
    slashes = 0;
    if (ch == L'\"') result += L'\\';
    result += ch;
  }
  result.append(slashes * 2, L'\\');
  return result + L'\"';
}
void Require(bool ok, const char* operation) {
  if (!ok) throw std::system_error(GetLastError(), std::system_category(), operation);
}
}

UINT GlobalSendUpdateExitMessage() {
  static const UINT message = RegisterWindowMessageW(L"GlobalSend.UpdateExit.v1");
  return message;
}

bool GlobalSendUpdateBackground(bool explicit_install, bool main_visible) {
  return !explicit_install || !main_visible;
}

void SignalGlobalSendUpdateReady() {
  wchar_t name[256]{};
  const DWORD size = GetEnvironmentVariableW(L"GLOBALSEND_UPDATE_READY_EVENT", name, 256);
  if (!size || size >= 256) return;
  if (const HANDLE event = OpenEventW(EVENT_MODIFY_STATE, FALSE, name)) {
    SetEvent(event);
    CloseHandle(event);
  }
  SetEnvironmentVariableW(L"GLOBALSEND_UPDATE_READY_EVENT", nullptr);
}

GlobalSendUpdateLaunch::~GlobalSendUpdateLaunch() {
  for (HANDLE event : {ready_, proceed_, cancel_, process_}) if (event) CloseHandle(event);
}
void GlobalSendUpdateLaunch::Continue() { SetEvent(proceed_); }
void GlobalSendUpdateLaunch::Cancel() { SetEvent(cancel_); }
bool GlobalSendUpdateLaunch::Running() const {
  return process_ && WaitForSingleObject(process_, 0) == WAIT_TIMEOUT;
}

std::shared_ptr<GlobalSendUpdateLaunch> GlobalSendUpdateLaunch::Start(
    const std::filesystem::path& package, const std::string& version,
    int64_t build, HWND window, bool background) {
  using namespace winrt::Windows::Data::Json;
  if (!package.is_absolute() || package.extension() != L".zip")
    throw std::invalid_argument("Windows automatic updates require an absolute ZIP path");
  const auto archive = std::filesystem::canonical(package);
  std::wstring executable(32768, L'\0');
  Require(GetModuleFileNameW(nullptr, executable.data(), static_cast<DWORD>(executable.size())) != 0,
          "GetModuleFileName");
  executable.resize(wcslen(executable.c_str()));
  const auto installed = std::filesystem::path(executable).parent_path();
  const auto script = installed / L"data/flutter_assets/assets/update/Install-WindowsUpdate.ps1";
  const auto work = archive.parent_path();
  // Run outside the installation folder, which this very helper replaces.
  const auto helper = work / L"Install-WindowsUpdate.ps1";
  std::filesystem::copy_file(script, helper, std::filesystem::copy_options::overwrite_existing);
  auto launch = std::make_shared<GlobalSendUpdateLaunch>();
  launch->result_path_ = work / L"windows-update-result.json";
  std::filesystem::remove(launch->result_path_);
  const auto token = std::to_wstring(GetCurrentProcessId()) + L"." + std::to_wstring(GetTickCount64());
  const auto prefix = L"Local\\GlobalSend.Update." + token;
  launch->ready_ = CreateEventW(nullptr, TRUE, FALSE, (prefix + L".ready").c_str());
  launch->proceed_ = CreateEventW(nullptr, TRUE, FALSE, (prefix + L".proceed").c_str());
  launch->cancel_ = CreateEventW(nullptr, TRUE, FALSE, (prefix + L".cancel").c_str());
  Require(launch->ready_ && launch->proceed_ && launch->cancel_, "Create update handshake");
  JsonObject request;
  request.SetNamedValue(L"package", JsonValue::CreateStringValue(archive.wstring()));
  request.SetNamedValue(L"installDirectory", JsonValue::CreateStringValue(installed.wstring()));
  request.SetNamedValue(L"executable", JsonValue::CreateStringValue(std::filesystem::path(executable).filename().wstring()));
  request.SetNamedValue(L"version", JsonValue::CreateStringValue(winrt::to_hstring(version)));
  request.SetNamedValue(L"build", JsonValue::CreateNumberValue(static_cast<double>(build)));
  request.SetNamedValue(L"processId", JsonValue::CreateNumberValue(GetCurrentProcessId()));
  request.SetNamedValue(L"window", JsonValue::CreateStringValue(std::to_wstring(reinterpret_cast<intptr_t>(window))));
  request.SetNamedValue(L"background", JsonValue::CreateBooleanValue(background));
  request.SetNamedValue(L"readyEvent", JsonValue::CreateStringValue(prefix + L".ready"));
  request.SetNamedValue(L"proceedEvent", JsonValue::CreateStringValue(prefix + L".proceed"));
  request.SetNamedValue(L"cancelEvent", JsonValue::CreateStringValue(prefix + L".cancel"));
  const auto request_path = work / (L"windows-update-" + token + L".json");
  std::ofstream output(request_path, std::ios::binary | std::ios::trunc);
  output << winrt::to_string(request.Stringify());
  output.close();
  if (!output) throw std::runtime_error("Unable to write update launch request");
  std::wstring system(32768, L'\0');
  const auto count = GetSystemDirectoryW(system.data(), static_cast<UINT>(system.size()));
  Require(count && count < system.size(), "GetSystemDirectory");
  system.resize(count);
  const auto powershell = std::filesystem::path(system) / L"WindowsPowerShell/v1.0/powershell.exe";
  auto command = Quote(powershell.wstring()) + L" -NoLogo -NoProfile -NonInteractive -File " +
      Quote(helper.wstring()) + L" -RequestPath " + Quote(request_path.wstring());
  STARTUPINFOW startup{sizeof(startup)};
  startup.dwFlags = STARTF_USESHOWWINDOW;
  startup.wShowWindow = SW_HIDE;
  PROCESS_INFORMATION process{};
  Require(CreateProcessW(powershell.c_str(), command.data(), nullptr, nullptr, FALSE,
      CREATE_NO_WINDOW, nullptr, work.c_str(), &startup, &process) != FALSE,
      "Start Windows updater");
  CloseHandle(process.hThread);
  launch->process_ = process.hProcess;
  const HANDLE waiting[] = {launch->ready_, process.hProcess};
  const DWORD status = WaitForMultipleObjects(2, waiting, FALSE, 15000);
  if (status != WAIT_OBJECT_0) {
    launch->Cancel();
    throw std::runtime_error(status == WAIT_TIMEOUT ? "Windows updater did not start" :
        "Windows updater could not run; the current app was not changed");
  }
  return launch;
}
