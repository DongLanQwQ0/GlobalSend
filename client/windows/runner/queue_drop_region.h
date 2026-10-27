#ifndef GLOBALSEND_QUEUE_DROP_REGION_H_
#define GLOBALSEND_QUEUE_DROP_REGION_H_
#include <windows.h>

// Coordinates reported by the visible Flutter queue, in physical client pixels.
struct GlobalSendQueueDropRegion {
  bool enabled = false;
  RECT bounds{};
  SIZE surface{};
  bool Contains(POINT point, SIZE current_surface) const {
    return enabled && current_surface.cx == surface.cx && current_surface.cy == surface.cy &&
        PtInRect(&bounds, point);
  }
};
#endif
