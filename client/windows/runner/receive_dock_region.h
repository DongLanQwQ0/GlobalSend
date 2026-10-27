#ifndef GLOBALSEND_RECEIVE_DOCK_REGION_H_
#define GLOBALSEND_RECEIVE_DOCK_REGION_H_

#include <windows.h>
#include <vector>

// Flutter supplies the current painted surface bounds, including clear AA
// padding. The same union clips composition and excludes gaps from hit tests.
inline HRGN GlobalSendReceiveDockRegion(const std::vector<RECT>& rects) {
  HRGN region = CreateRectRgn(0, 0, 0, 0);
  for (const auto& rect : rects) {
    HRGN part = CreateRectRgn(rect.left, rect.top, rect.right, rect.bottom);
    CombineRgn(region, region, part, RGN_OR);
    DeleteObject(part);
  }
  return region;
}
#endif
