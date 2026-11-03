#ifndef GLOBALSEND_RECEIVE_DOCK_H_
#define GLOBALSEND_RECEIVE_DOCK_H_
#include "win32_window.h"
#include "receive_dock_geometry.h"
#include "update_interaction.h"
#include <flutter/encodable_value.h>
#include <flutter/flutter_view_controller.h>
#include <flutter/method_channel.h>
#include <functional>
#include <memory>
#include <algorithm>
#include <utility>
#include <vector>
#include <string>
#include <oleidl.h>
#include <set>

// Native touch export completes asynchronously. Hold the source window until
// the platform reply really completes, not merely until the start function returns.
class GlobalSendDockDragReply final : public flutter::MethodResult<flutter::EncodableValue> {
 public:
  using Value = flutter::EncodableValue;
  GlobalSendDockDragReply(std::unique_ptr<flutter::MethodResult<Value>> reply, std::function<void()> done)
      : reply_(std::move(reply)), done_(std::move(done)) {}
 protected:
  void SuccessInternal(const Value* value) override {
    if (value) reply_->Success(*value); else reply_->Success();
    done_();
  }
  void ErrorInternal(const std::string& code, const std::string& message, const Value* details) override {
    if (details) reply_->Error(code, message, *details); else reply_->Error(code, message);
    done_();
  }
  void NotImplementedInternal() override { reply_->NotImplemented(); done_(); }
 private:
  std::unique_ptr<flutter::MethodResult<Value>> reply_;
  std::function<void()> done_;
};

// A display-only engine: no plugins, credentials, network controller or tray.
class GlobalSendReceiveDock final : public Win32Window {
 public:
  using Map = flutter::EncodableMap;
  using Action = std::function<void(const Map&)>;
  using Drag = std::function<void(const Map&,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>, HWND,
      std::function<void()>)>;
  GlobalSendReceiveDock(Map payload, Action action, Drag drag, std::function<void()> shown,
      std::function<void(int64_t)> closed, std::function<void(bool)> interaction = {});
  ~GlobalSendReceiveDock() override;
  bool Open();
  void Update(Map payload);
  void HideAnimated();
  void ClearContent();
  bool Shown() const { return shown_; }
  bool Ready() const { return ready_; }
  bool ClosingFinished() const { return closing_finished_; }
  bool Interacting() const { return dragging_ || moving_ || hovering_drop_ || interaction_.Busy(); }
  int64_t Generation() const;
 protected:
  bool OnCreate() override;
  void OnDestroy() override;
  LRESULT MessageHandler(HWND hwnd, UINT message, WPARAM wp, LPARAM lp) noexcept override;
 private:
  void Position();
  void ReflowDisplay(const RECT* suggested = nullptr);
  void Animate(bool closing);
  void Tick();
  void BeginMove(const Map& args);
  void TickMove();
  void EndMove();
  void TrackDrop(bool active, POINTL point);
  std::string DropDeviceAt(POINTL point) const;
  void SetDropRegions(const Map& regions);
  void NotifyInteraction();
  void RetainClipboardSlot();
  void ReleaseClipboardSlotsExcept(const std::string& path);
  std::string ClipboardSlotPath() const;
  std::set<std::string> clipboard_slot_paths_;
  static LRESULT CALLBACK InteractionObserver(HWND, UINT, WPARAM, LPARAM, UINT_PTR, DWORD_PTR);
  Map payload_;
  Action action_;
  Drag drag_;
  std::function<void()> first_frame_;
  std::function<void(int64_t)> closed_;
  std::function<void(bool)> interaction_changed_;
  GlobalSendUpdateInteraction interaction_;
  bool interaction_published_ = false;
  std::unique_ptr<flutter::FlutterViewController> controller_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> system_channel_;
  IDropTarget* drop_target_ = nullptr;
  std::vector<HWND> drop_windows_;
  bool shown_ = false;
  bool ready_ = false;
  bool presentation_scheduled_ = false;
  bool closing_ = false;
  bool closing_finished_ = false;
  bool dragging_ = false, moving_ = false;
  bool animating_ = false;
  bool hovering_drop_ = false;
  POINTL drop_pointer_{};
  SIZE drop_surface_{};
  std::string drop_server_key_;
  std::vector<std::pair<std::string, RECT>> drop_devices_;
  bool moving_touch_ = false;
  RECT move_start_{};
  POINT move_anchor_{};
  ULONGLONG animation_start_ = 0;
  int animation_from_ = 0, animation_to_ = 0;
  RECT resting_{};
  uintptr_t frame_token_ = 0;
  uintptr_t instance_token_ = 0;
};
#endif
