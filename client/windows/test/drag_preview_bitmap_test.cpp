#include "../runner/drag_preview.h"
#include <cassert>
#include <fstream>
#include <iostream>

void Check(const std::wstring& text, int expected_height, const char* destination) {
  const auto image = GlobalSendTextDragBitmap(text);
  assert(image);
  DIBSECTION shape{};
  assert(GetObjectW(image, sizeof(shape), &shape) == sizeof(shape));
  assert(shape.dsBm.bmWidth == 216 && shape.dsBm.bmHeight == expected_height);
  const auto* pixels = static_cast<const uint32_t*>(shape.dsBm.bmBits);
  assert(pixels && pixels[0] == 0 && pixels[215] == 0);
  int translucent = 0, ink = 0, green = 0;
  for (int i = 0; i < 216 * expected_height; ++i) {
    const auto pixel = pixels[i];
    const auto alpha = pixel >> 24;
    const auto red = (pixel >> 16) & 255, g = (pixel >> 8) & 255, blue = pixel & 255;
    assert(red <= alpha && g <= alpha && blue <= alpha);
    if (alpha > 0 && alpha < 220) ++translucent;
    if (alpha > 230 && red < 100 && g < 130 && blue < 110) ++ink;
    if (alpha > 230 && g > red + 25 && g > blue + 10) ++green;
  }
  assert(translucent > 300 && ink > 50 && green > 30);
  std::ofstream file(destination, std::ios::binary);
  const int dimensions[]{216, expected_height};
  file.write(reinterpret_cast<const char*>(dimensions), sizeof(dimensions));
  file.write(reinterpret_cast<const char*>(pixels), 216 * expected_height * 4);
  DeleteObject(image);
}

int main() {
  const std::vector<uint8_t> rgba{10, 20, 30, 40, 100, 110, 120, 130};
  auto snapshot = GlobalSendDragBitmapFromRgba(rgba, 2, 1);
  assert(snapshot);
  DIBSECTION converted{};
  assert(GetObjectW(snapshot, sizeof(converted), &converted) == sizeof(converted));
  assert(converted.dsBm.bmWidth == 2 && converted.dsBm.bmHeight == 1);
  const auto* pixels = static_cast<const uint8_t*>(converted.dsBm.bmBits);
  const std::vector<uint8_t> expected{30, 20, 10, 40, 120, 110, 100, 130};
  assert(std::equal(expected.begin(), expected.end(), pixels));
  DeleteObject(snapshot);
  assert(!GlobalSendDragBitmapFromRgba(rgba, 2, 2));
  auto fallback = GlobalSendContentDragBitmap(L"", {L"Z:\\not-mounted\\image.jpg"});
  assert(fallback);
  DeleteObject(fallback);
  Check(L"192.168.1.12:8787", 88, "artifacts/tmp/windows-drag-final/short.bgra");
  Check(L"周六上午九点集合。\n新收到的内容可以拖出，正文也可以选择复制。更长的摘要应自然截断。", 132,
      "artifacts/tmp/windows-drag-final/long.bgra");
  std::cout << "PASS rounded native drag paper, transparent corners, soft alpha edge, readable glyphs and copy accent\n";
}
