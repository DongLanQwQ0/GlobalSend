#ifndef GLOBALSEND_UPDATE_INTERACTION_H_
#define GLOBALSEND_UPDATE_INTERACTION_H_
#include <windows.h>
#include <cstdint>
#include <array>
#include <functional>
#include <set>
#include <utility>

// Real native lifetimes, including the OLE nested message loop. A Flutter
// gesture may retire its pointer before the operating system ends the drag.
class GlobalSendUpdateInteraction {
 public:
  enum Reason { export_operation, drop_hover, window_move, native_menu, flutter_operation, count };
  explicit GlobalSendUpdateInteraction(std::function<void()> changed = {}) : changed_(std::move(changed)) {}
  bool Busy() const {
    for (const bool active : reasons_) if (active) return true;
    return !contacts_.empty();
  }
  void Set(Reason reason, bool active) {
    const bool before = Busy(); reasons_[reason] = active; Publish(before);
  }
  void ReleasePointers() {
    const bool before = Busy(); contacts_.clear(); Publish(before);
  }
  void Observe(HWND window, UINT message, WPARAM wp) {
    const bool before = Busy();
    UINT token = 0; bool down = false, up = false;
    switch (message) {
      case WM_LBUTTONDOWN: case WM_LBUTTONDBLCLK: token = MK_LBUTTON; down = true; break;
      case WM_RBUTTONDOWN: case WM_RBUTTONDBLCLK: token = MK_RBUTTON; down = true; break;
      case WM_MBUTTONDOWN: case WM_MBUTTONDBLCLK: token = MK_MBUTTON; down = true; break;
      case WM_LBUTTONUP: token = MK_LBUTTON; up = true; break;
      case WM_RBUTTONUP: token = MK_RBUTTON; up = true; break;
      case WM_MBUTTONUP: token = MK_MBUTTON; up = true; break;
      case WM_XBUTTONDOWN: case WM_XBUTTONDBLCLK: token = HIWORD(wp) == XBUTTON1 ? MK_XBUTTON1 : MK_XBUTTON2; down = true; break;
      case WM_XBUTTONUP: token = HIWORD(wp) == XBUTTON1 ? MK_XBUTTON1 : MK_XBUTTON2; up = true; break;
      case WM_POINTERDOWN: token = 0x10000 + GET_POINTERID_WPARAM(wp); down = true; break;
      case WM_POINTERUP: case WM_POINTERCAPTURECHANGED: token = 0x10000 + GET_POINTERID_WPARAM(wp); up = true; break;
      case WM_ENTERSIZEMOVE: reasons_[window_move] = true; break;
      case WM_EXITSIZEMOVE: reasons_[window_move] = false; break;
      case WM_ENTERMENULOOP: reasons_[native_menu] = true; break;
      case WM_EXITMENULOOP: reasons_[native_menu] = false; break;
      case WM_CAPTURECHANGED: case WM_CANCELMODE: case WM_DESTROY:
        for (auto it = contacts_.begin(); it != contacts_.end();) {
          if (it->first == window) it = contacts_.erase(it); else ++it;
        }
        break;
    }
    if (down) contacts_.emplace(window, token);
    if (up) contacts_.erase({window, token});
    Publish(before);
  }
 private:
  void Publish(bool before) { if (before != Busy() && changed_) changed_(); }
  std::array<bool, count> reasons_{};
  std::set<std::pair<HWND, UINT>> contacts_;
  std::function<void()> changed_;
};

// An approval only authorizes a final check, never an unchecked DestroyWindow.
class GlobalSendUpdateExitGate {
 public:
  void InteractionBegan() { ++revision_; approved_ = false; }
  void Request() { requested_ = true; approved_ = false; }
  bool Prepare(bool interacting) {
    if (!requested_ || querying_ || approved_ || interacting) return false;
    querying_ = true; query_revision_ = revision_; return true;
  }
  bool Resolve(bool accepted, bool interacting) {
    querying_ = false;
    if (!requested_) return false;
    approved_ = accepted && !interacting && query_revision_ == revision_;
    return approved_;
  }
  bool Complete(bool interacting) {
    if (interacting) approved_ = false;
    if (!requested_ || !approved_) return false;
    Cancel(); return true;
  }
  void Cancel() { requested_ = querying_ = approved_ = false; }
  bool Requested() const { return requested_; }
  bool FreshCheckNeeded() const { return requested_ && query_revision_ != revision_; }
 private:
  bool requested_ = false, querying_ = false, approved_ = false;
  uint64_t revision_ = 0, query_revision_ = 0;
};
#endif
