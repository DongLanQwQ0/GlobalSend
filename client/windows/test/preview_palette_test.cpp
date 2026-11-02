#include "../runner/drag_preview.h"
#include <cassert>
#include <iostream>
int main() {
  const GlobalSendDragPalette palette{0xff25232b, 0xffeeeeee, 0xffc9a7f2, 0xff655371};
  for (const auto paths : {std::vector<std::wstring>{}, std::vector<std::wstring>{L"C:\\sample\\photo.png"}}) {
    HBITMAP bitmap = GlobalSendContentDragBitmap(L"clipboard text", paths, palette);
    DIBSECTION dib{}; assert(bitmap && GetObjectW(bitmap, sizeof(dib), &dib));
    const auto* pixels = static_cast<const uint32_t*>(dib.dsBm.bmBits);
    size_t background = 0, accent = 0;
    for (int index = 0; index < dib.dsBm.bmWidth * dib.dsBm.bmHeight; ++index) {
      if (pixels[index] == palette.background) ++background;
      if (pixels[index] == palette.accent) ++accent;
      assert(pixels[index] != 0xff176b50);
    }
    assert(background > 1000 && accent > 10); DeleteObject(bitmap);
  }
  std::cout << "PASS native text/file fallback preserves supplied dark/purple palette without green pixels\n";
}
