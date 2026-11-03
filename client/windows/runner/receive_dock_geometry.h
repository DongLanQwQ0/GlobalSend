#ifndef GLOBALSEND_RECEIVE_DOCK_GEOMETRY_H_
#define GLOBALSEND_RECEIVE_DOCK_GEOMETRY_H_
#include <windows.h>
#include <algorithm>

inline RECT GlobalSendReceiveDockFitBounds(const RECT& desired, const RECT& work) {
  const LONG width = std::min(std::max(1L, desired.right - desired.left), std::max(1L, work.right - work.left));
  const LONG height = std::min(std::max(1L, desired.bottom - desired.top), std::max(1L, work.bottom - work.top));
  const LONG left = std::clamp(desired.left, work.left, std::max(work.left, work.right - width));
  const LONG top = std::clamp(desired.top, work.top, std::max(work.top, work.bottom - height));
  return {left, top, left + width, top + height};
}

inline RECT GlobalSendReceiveDockBounds(const RECT& work, UINT dpi, bool /*multiple*/) {
  const int margin = MulDiv(16, static_cast<int>(dpi), 96);
  const int width = std::min(MulDiv(480, static_cast<int>(dpi), 96),
      static_cast<int>(std::max(1L, work.right - work.left - margin * 2)));
  const int height = std::min(MulDiv(184, static_cast<int>(dpi), 96),
      static_cast<int>(std::max(1L, work.bottom - work.top - margin * 2)));
  return GlobalSendReceiveDockFitBounds({work.right - width - margin, work.bottom - height - margin,
      work.right - margin, work.bottom - margin}, work);
}

inline POINT GlobalSendReceiveDockMoveOrigin(RECT start, POINT down, POINT now) {
  return {start.left + now.x - down.x, start.top + now.y - down.y};
}
#endif
