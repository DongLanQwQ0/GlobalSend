#include "../runner/clipboard_image.h"
#include <cassert>
#include <filesystem>
#include <fstream>
#include <cstring>
#include <iostream>

// Pure image conversion: never opens a user window or touches the OS clipboard.
int wmain(int argc, wchar_t** argv) {
  assert(argc == 2);
  assert(SUCCEEDED(CoInitializeEx(nullptr, COINIT_MULTITHREADED)));
  const std::filesystem::path root(argv[1]);
  std::filesystem::create_directories(root);
  const auto path = root / L"clipboard-colors.bmp";
  BITMAPFILEHEADER file{};
  file.bfType = 0x4d42;
  file.bfOffBits = sizeof(file) + sizeof(BITMAPINFOHEADER);
  file.bfSize = file.bfOffBits + 8;
  BITMAPINFOHEADER bitmap{};
  bitmap.biSize = sizeof(bitmap);
  bitmap.biWidth = 2; bitmap.biHeight = -1;
  bitmap.biPlanes = 1; bitmap.biBitCount = 32;
  const unsigned char pixels[] = {0, 0, 255, 255, 255, 0, 0, 255};
  {
    std::ofstream out(path, std::ios::binary);
    out.write(reinterpret_cast<const char*>(&file), sizeof(file));
    out.write(reinterpret_cast<const char*>(&bitmap), sizeof(bitmap));
    out.write(reinterpret_cast<const char*>(pixels), sizeof(pixels));
  }
  const auto image = PrepareGlobalSendClipboardImage(path.wstring());
  assert(SUCCEEDED(image.status));
  const unsigned char png[] = {137,80,78,71,13,10,26,10};
  assert(image.png.size() > sizeof(png) && memcmp(image.png.data(), png, sizeof(png)) == 0);
  assert(image.dib_v5.size() == sizeof(BITMAPV5HEADER) + sizeof(pixels));
  const auto* v5 = reinterpret_cast<const BITMAPV5HEADER*>(image.dib_v5.data());
  assert(v5->bV5Width == 2 && v5->bV5Height == -1 && v5->bV5BitCount == 32);
  assert(v5->bV5RedMask == 0x00ff0000 && v5->bV5AlphaMask == 0xff000000);
  assert(memcmp(image.dib_v5.data() + sizeof(*v5), pixels, sizeof(pixels)) == 0);
  assert(image.dib.size() == sizeof(BITMAPINFOHEADER) + sizeof(pixels));
  const auto png_path = root / L"converted.png";
  { std::ofstream out(png_path, std::ios::binary); out.write(reinterpret_cast<const char*>(image.png.data()), image.png.size()); }
  const auto roundtrip = PrepareGlobalSendClipboardImage(png_path.wstring());
  assert(SUCCEEDED(roundtrip.status) && roundtrip.dib_v5 == image.dib_v5);
  assert(FAILED(PrepareGlobalSendClipboardImage((root / L"missing.png").wstring()).status));
  std::cout << "PASS: WIC BMP/PNG -> PNG + DIB + DIBV5, exact dimensions/colors; no OS clipboard access\n";
  CoUninitialize();
}
