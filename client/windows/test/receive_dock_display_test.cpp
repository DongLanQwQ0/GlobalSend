#include "../runner/receive_dock_geometry.h"
#include <cassert>
#include <iostream>
void inside(RECT r, RECT work) {
  assert(r.left >= work.left && r.top >= work.top);
  assert(r.right <= work.right && r.bottom <= work.bottom);
  assert(r.right > r.left && r.bottom > r.top);
}
int main() {
  const RECT large{0,0,3840,2160}, compact{0,0,1280,720};
  const auto old = GlobalSendReceiveDockBounds(large,144,false);
  inside(GlobalSendReceiveDockFitBounds(old,compact),compact);
  const RECT secondary{-1920,0,0,1080};
  inside(GlobalSendReceiveDockFitBounds({-1800,50,-1320,234},compact),compact);
  const RECT user{35,80,515,264};
  const auto stable=GlobalSendReceiveDockFitBounds(user,compact);
  assert(EqualRect(&user,&stable));
  for(UINT dpi: {96u,120u,144u,192u}) {
    for(RECT work: {large,compact,secondary,RECT{0,40,800,600},RECT{0,0,15,12}}) {
      const auto home=GlobalSendReceiveDockBounds(work,dpi,false);
      inside(home,work);
      inside(GlobalSendReceiveDockFitBounds({5000,4000,5960,4368},work),work);
    }
  }
  std::cout<<"PASS resolution shrink, removed/negative monitor, work-area, DPI, tiny screen, preserved user position\n";
}
