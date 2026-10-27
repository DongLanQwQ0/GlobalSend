#ifndef GLOBALSEND_RECEIVE_DOCK_H_
#define GLOBALSEND_RECEIVE_DOCK_H_
#include "win32_window.h"
#include <flutter/encodable_value.h>
#include <flutter/flutter_view_controller.h>
#include <flutter/method_channel.h>
#include <functional>
#include <memory>
#include <algorithm>
#include <utility>
#include <vector>
#include <oleidl.h>

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

inline RECT GlobalSendReceiveDockBounds(const RECT& work, UINT dpi, bool /*multiple*/) {
  const int margin = MulDiv(16, static_cast<int>(dpi), 96);
  const int width = std::min(MulDiv(480, static_cast<int>(dpi), 96),
      static_cast<int>(std::max(1L, work.right - work.left - margin * 2)));
  const int height = std::min(MulDiv(184, static_cast<int>(dpi), 96),
      static_cast<int>(std::max(1L, work.bottom - work.top - margin * 2)));
  return {work.right - width - margin, work.bottom - height - margin,
      work.right - margin, work.bottom - margin};
}

inline POINT GlobalSendReceiveDockMoveOrigin(RECT start, POINT down, POINT now) {
  return {start.left + now.x - down.x, start.top + now.y - down.y};
}

// A display-only engine: no plugins, credentials, network controller or tray.
class GlobalSendReceiveDock final : public Win32Window {
 public:
  using Map = flutter::EncodableMap;
  using Action = std::function<void(const Map&)>;
  using Drag = std::function<void(const Map&,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>, HWND)>;
  GlobalSendReceiveDock(Map payload, Action action, Drag drag, std::function<void()> shown,
      std::function<void(int64_t)> closed);
  ~GlobalSendReceiveDock() override;
  bool Open();
  void Update(Map payload);
  void HideAnimated();
  bool Shown() const { return shown_; }
  bool ClosingFinished() const { return closing_finished_; }
  bool Interacting() const { return dragging_ || moving_; }
  int64_t Generation() const;
 protected:
  bool OnCreate() override;
  void OnDestroy() override;
  LRESULT MessageHandler(HWND hwnd, UINT message, WPARAM wp, LPARAM lp) noexcept override;
 private:
  void Position();
  void Animate(bool closing);
  void Tick();
  void BeginMove(const Map& args);
  void TickMove();
  void EndMove();
  Map payload_;
  Action action_;
  Drag drag_;
  std::function<void()> first_frame_;
  std::function<void(int64_t)> closed_;
  std::unique_ptr<flutter::FlutterViewController> controller_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
  IDropTarget* drop_target_ = nullptr;
  std::vector<HWND> drop_windows_;
  bool shown_ = false;
  bool presentation_scheduled_ = false;
  bool closing_ = false;
  bool closing_finished_ = false;
  bool dragging_ = false, moving_ = false;
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
