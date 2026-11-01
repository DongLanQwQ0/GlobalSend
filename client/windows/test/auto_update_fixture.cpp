#include <windows.h>
#include <fstream>
#include <filesystem>
#include <string>
int wmain(int count, wchar_t** arguments) {
  if (std::filesystem::exists("fail-first-frame.flag")) return 9;
  std::ofstream record("restart.txt", std::ios::app);
  for (int i = 1; i < count; ++i) {
    const std::wstring value(arguments[i]);
    for (const auto character : value) record << static_cast<char>(character);
    record << '\n';
  }
  record << "started\n";
  record.close();
  wchar_t event_name[256]{};
  if (GetEnvironmentVariableW(L"GLOBALSEND_UPDATE_READY_EVENT", event_name, 256)) {
    if (const HANDLE event = OpenEventW(EVENT_MODIFY_STATE, FALSE, event_name)) {
      SetEvent(event); CloseHandle(event);
    }
  }
  return 0;
}
