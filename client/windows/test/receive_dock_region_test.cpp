#include "../runner/receive_dock_region.h"
#include <cassert>
#include <fstream>
#include <iostream>
#include <string>

int main(int argc, char** argv) {
  assert(argc == 2);
  std::ifstream input(argv[1]);
  assert(input);
  std::string tag, name;
  size_t count = 0, points = 0, frames = 0, missing = 0;
  while (input >> tag >> name >> count >> points) {
    assert(tag == "FRAME");
    std::vector<RECT> rects(count);
    for (auto& r : rects) input >> r.left >> r.top >> r.right >> r.bottom;
    const auto region = GlobalSendReceiveDockRegion(rects);
    for (size_t i = 0; i < points; ++i) {
      int x = 0, y = 0;
      input >> x >> y;
      if (!PtInRegion(region, x, y)) ++missing;
    }
    DeleteObject(region);
    ++frames;
  }
  std::cout << "frames=" << frames << " missing_painted_samples=" << missing << "\n";
  assert(frames > 0);
  if (missing != 0) return 1;
  const auto region = GlobalSendReceiveDockRegion({{10, 40, 152, 180}, {162, 40, 304, 180}});
  assert(PtInRegion(region, 20, 80));
  assert(!PtInRegion(region, 157, 80)); // real gaps are still click-through
  assert(!PtInRegion(region, 310, 15)); // no full-window grey/interactive sheet
  DeleteObject(region);
  std::cout << "PASS production region union preserves every current paint sample and excludes blank gaps\n";
}
