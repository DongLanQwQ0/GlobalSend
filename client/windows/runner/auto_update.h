#ifndef GLOBALSEND_AUTO_UPDATE_H_
#define GLOBALSEND_AUTO_UPDATE_H_
#include <windows.h>
#include <filesystem>
#include <memory>
#include <string>

UINT GlobalSendUpdateExitMessage();
void SignalGlobalSendUpdateReady();
// Losing focus does not imply the visible main window should regain focus.
bool GlobalSendUpdateBackground(bool explicit_install, bool main_visible);

// The helper owns extraction and replacement after the old process has exited.
// This object owns only its launch handshake, never another app's lifetime.
class GlobalSendUpdateLaunch {
 public:
  ~GlobalSendUpdateLaunch();
  void Continue();
  void Cancel();
  bool Running() const;
  const std::filesystem::path& ResultPath() const { return result_path_; }
  uintptr_t ExitToken() const { return exit_token_; }
  static std::shared_ptr<GlobalSendUpdateLaunch> Start(
      const std::filesystem::path& package, const std::string& version,
      int64_t build, HWND window, bool background, uintptr_t request_token = 0);
 private:
  HANDLE ready_ = nullptr;
  HANDLE proceed_ = nullptr;
  HANDLE cancel_ = nullptr;
  HANDLE process_ = nullptr;
  std::filesystem::path result_path_;
  uintptr_t exit_token_ = 0;
};
#endif
