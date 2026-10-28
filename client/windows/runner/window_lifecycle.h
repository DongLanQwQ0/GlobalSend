#ifndef GLOBALSEND_WINDOW_LIFECYCLE_H_
#define GLOBALSEND_WINDOW_LIFECYCLE_H_
#include <windows.h>
#include <functional>
#include <cstdint>
#include <optional>
#include <string>
#include <vector>

struct GlobalSendWindowState {
  int left = 10;
  int top = 10;
  int width = 950;
  int height = 650;
  bool maximized = false;
};

// Bounds are physical screen pixels, as returned by WINDOWPLACEMENT.
GlobalSendWindowState FitGlobalSendWindow(GlobalSendWindowState state,
                                        const RECT& work);
bool GlobalSendReceiptFullscreen(const RECT& work,
                                 const std::vector<RECT>& app_windows);

class GlobalSendWindowLifecycle {
 public:
  using Visibility = std::function<void(bool)>;
  using Save = std::function<void(const GlobalSendWindowState&)>;
  GlobalSendWindowLifecycle(HWND window, Visibility visibility, Save save);
  ~GlobalSendWindowLifecycle();
  bool Handle(UINT message, WPARAM wparam, LPARAM lparam, LRESULT* result);
  void Restore(const GlobalSendWindowState& state);
  GlobalSendWindowState State() const;
  // Dart must remain mounted while the native HWND waits for its first frame.
  bool Visible() const;
  void ShowOnFirstFrame();
  bool ShowReceived();
  bool Focused() const;
  void Activate();
  void DismissReceived(std::optional<uint64_t> expected_generation = std::nullopt);
  uint64_t ReceiptArrivalGeneration() const { return receipt_arrival_generation_; }
  bool NotifyReceived(const std::wstring& title, const std::wstring& body, bool update = false);
  bool UpdateNotice() const { return update_notice_; }
 private:
  bool AddTray();
  void Show();
  void SaveState();
  HWND window_;
  Visibility visibility_;
  Save save_;
  UINT taskbar_created_;
  bool tray_ = false;
  bool update_notice_ = false;
  bool exiting_ = false;
  bool restoring_ = false;
  bool maximized_ = false;
  bool ui_visible_ = true;
  bool receipt_presentation_ = false;
  uint64_t receipt_arrival_generation_ = 0;
  GlobalSendWindowState before_receipt_;
};
#endif
