#ifndef GLOBALSEND_SINGLE_INSTANCE_H_
#define GLOBALSEND_SINGLE_INSTANCE_H_
#include <windows.h>
#include <string>
#include <functional>
#include <vector>

UINT GlobalSendActivateMessage();
struct GlobalSendLaunchOptions {
  bool background = false;
  std::vector<std::wstring> paths;
};
GlobalSendLaunchOptions ParseGlobalSendLaunchOptions(int count, const wchar_t* const* arguments);
GlobalSendLaunchOptions GlobalSendLaunchFromCommandLine();
std::vector<std::wstring> GlobalSendPathsFromCommandLine();
void QueueGlobalSendLaunchPaths(std::vector<std::wstring> paths);
void SetGlobalSendLaunchConsumer(
    std::function<void(std::vector<std::wstring>)> consumer);
void DrainGlobalSendLaunchFiles();
bool HandleGlobalSendLaunchMessage(UINT message, LPARAM parameter, LRESULT* result);

// Acquire before initializing Flutter. The owner holds the mutex for the
// lifetime of its receiver engine, including while its window is in the tray.
class GlobalSendSingleInstance {
 public:
  enum class Start { primary, activated, failed };
  explicit GlobalSendSingleInstance(const std::wstring& app = L"GlobalSend");
  ~GlobalSendSingleInstance();
  GlobalSendSingleInstance(const GlobalSendSingleInstance&) = delete;
  GlobalSendSingleInstance& operator=(const GlobalSendSingleInstance&) = delete;
  Start AcquireOrActivate(DWORD timeout_ms = 30000,
      const std::vector<std::wstring>& paths = {}, bool activate = true);
  bool AttachWindow(HWND window);
 private:
  HANDLE mutex_ = nullptr;
  HWND window_ = nullptr;
  bool owned_ = false;
  std::wstring window_property_;
};
#endif
