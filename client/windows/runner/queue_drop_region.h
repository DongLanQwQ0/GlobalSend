#ifndef GLOBALSEND_QUEUE_DROP_REGION_H_
#define GLOBALSEND_QUEUE_DROP_REGION_H_
#include <windows.h>
#include <vector>

// Coordinates reported by the visible Flutter queue, in physical client pixels.
struct GlobalSendQueueDropRegion {
  bool enabled = false;
  RECT bounds{};
  SIZE surface{};
  std::vector<RECT> exclusions;

  bool Excludes(POINT point, SIZE current_surface) const {
    if (!enabled || current_surface.cx != surface.cx || current_surface.cy != surface.cy) return false;
    for (const auto& region : exclusions) if (PtInRect(&region, point)) return true;
    return false;
  }
  bool Contains(POINT point, SIZE current_surface) const {
    return enabled && current_surface.cx == surface.cx && current_surface.cy == surface.cy &&
        PtInRect(&bounds, point) && !Excludes(point, current_surface);
  }
};
#endif
