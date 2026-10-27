#include "drag_preview.h"
#include <shlobj.h>
#include <shobjidl.h>
#include <algorithm>
#include <cstdint>
#include <cstring>
#include <gdiplus.h>
#include <memory>
#pragma comment(lib, "gdiplus.lib")

namespace {
std::unique_ptr<Gdiplus::GraphicsPath> Rounded(float x, float y, float width, float height, float radius) {
  auto path = std::make_unique<Gdiplus::GraphicsPath>();
  const float diameter = radius * 2;
  path->AddArc(x, y, diameter, diameter, 180, 90);
  path->AddArc(x + width - diameter, y, diameter, diameter, 270, 90);
  path->AddArc(x + width - diameter, y + height - diameter, diameter, diameter, 0, 90);
  path->AddArc(x, y + height - diameter, diameter, diameter, 90, 90);
  path->CloseFigure();
  return path;
}
}

HRESULT CreateGlobalSendDragData(CLIPFORMAT format,
    const std::vector<uint8_t>& bytes, IDataObject** output) {
  if (!output) return E_POINTER;
  *output = nullptr;
  IDataObject* data = nullptr;
  HRESULT result = SHCreateDataObject(nullptr, 0, nullptr, nullptr,
      IID_PPV_ARGS(&data));
  if (FAILED(result)) return result;
  STGMEDIUM medium{};
  medium.tymed = TYMED_HGLOBAL;
  medium.hGlobal = GlobalAlloc(GMEM_MOVEABLE, bytes.size());
  void* destination = medium.hGlobal ? GlobalLock(medium.hGlobal) : nullptr;
  if (!destination) {
    if (medium.hGlobal) GlobalFree(medium.hGlobal);
    data->Release();
    return E_OUTOFMEMORY;
  }
  memcpy(destination, bytes.data(), bytes.size());
  GlobalUnlock(medium.hGlobal);
  FORMATETC payload{format, nullptr, DVASPECT_CONTENT, -1, TYMED_HGLOBAL};
  result = data->SetData(&payload, &medium, TRUE);
  if (FAILED(result)) {
    ReleaseStgMedium(&medium);
    data->Release();
    return result;
  }
  *output = data;
  return S_OK;
}

HBITMAP GlobalSendTextDragBitmap(const std::wstring& text) {
  constexpr int width = 216;
  const bool short_text = text.size() <= 24 && text.find_first_of(L"\r\n") == std::wstring::npos;
  const int height = short_text ? 88 : 132;
  BITMAPINFO info{};
  info.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
  info.bmiHeader.biWidth = width;
  info.bmiHeader.biHeight = -height;
  info.bmiHeader.biPlanes = 1;
  info.bmiHeader.biBitCount = 32;
  info.bmiHeader.biCompression = BI_RGB;
  uint32_t* pixels = nullptr;
  HBITMAP bitmap = CreateDIBSection(nullptr, &info, DIB_RGB_COLORS,
      reinterpret_cast<void**>(&pixels), nullptr, 0);
  if (!bitmap) return nullptr;
  std::fill(pixels, pixels + width * height, 0);
  Gdiplus::GdiplusStartupInput startup;
  ULONG_PTR token{};
  if (Gdiplus::GdiplusStartup(&token, &startup, nullptr) != Gdiplus::Ok) {
    DeleteObject(bitmap);
    return nullptr;
  }
  {
    Gdiplus::Bitmap image(width, height, width * 4, PixelFormat32bppPARGB,
        reinterpret_cast<BYTE*>(pixels));
    Gdiplus::Graphics graphics(&image);
    graphics.SetSmoothingMode(Gdiplus::SmoothingModeAntiAlias);
    graphics.SetTextRenderingHint(Gdiplus::TextRenderingHintAntiAliasGridFit);
    // Rounded, premultiplied-alpha paper and a small soft shadow. Transparent
    // corners stay transparent when the shell transports the native image.
    for (int spread = 5; spread >= 1; --spread) {
      auto shadow = Rounded(6.0f - spread, 6.0f - spread,
          204.0f + spread * 2, static_cast<float>(height - 16 + spread * 2), 14.0f + spread);
      Gdiplus::SolidBrush shade(Gdiplus::Color(5, 20, 38, 28));
      graphics.FillPath(&shade, shadow.get());
    }
    auto paper = Rounded(6, 4, 204, static_cast<float>(height - 12), 14);
    Gdiplus::SolidBrush white(Gdiplus::Color(248, 250, 253, 250));
    graphics.FillPath(&white, paper.get());
    Gdiplus::Pen border(Gdiplus::Color(150, 219, 229, 220), 1);
    graphics.DrawPath(&border, paper.get());
    auto preview = text.substr(0, 160);
    if (text.size() > preview.size()) preview += L"…";
    Gdiplus::FontFamily family(L"Microsoft YaHei UI");
    Gdiplus::Font body(&family, 14, Gdiplus::FontStyleRegular, Gdiplus::UnitPixel);
    Gdiplus::SolidBrush ink(Gdiplus::Color(255, 32, 41, 35));
    Gdiplus::StringFormat format;
    format.SetTrimming(Gdiplus::StringTrimmingEllipsisCharacter);
    Gdiplus::RectF bounds(18, 15, 180, static_cast<float>(height - 53));
    graphics.DrawString(preview.c_str(), static_cast<int>(preview.size()), &body, bounds, &format, &ink);
    const float footer = static_cast<float>(height - 31);
    Gdiplus::Pen green(Gdiplus::Color(255, 23, 107, 80), 1.4f);
    auto copy_back = Rounded(18, footer, 9, 11, 1.5f);
    auto copy_front = Rounded(21, footer + 3, 9, 11, 1.5f);
    graphics.DrawPath(&green, copy_back.get());
    graphics.DrawPath(&green, copy_front.get());
    Gdiplus::Font label(&family, 12, Gdiplus::FontStyleRegular, Gdiplus::UnitPixel);
    Gdiplus::SolidBrush accent(Gdiplus::Color(255, 23, 107, 80));
    graphics.DrawString(L"复制", 2, &label, Gdiplus::PointF(37, footer - 1), &accent);
  }
  Gdiplus::GdiplusShutdown(token);
  return bitmap;
}

HBITMAP GlobalSendContentDragBitmap(const std::wstring& text,
    const std::vector<std::wstring>& paths) {
  if (paths.empty()) return GlobalSendTextDragBitmap(text);
  HBITMAP bitmap = nullptr;
  IShellItemImageFactory* factory = nullptr;
  if (SUCCEEDED(SHCreateItemFromParsingName(paths.front().c_str(), nullptr,
      IID_PPV_ARGS(&factory)))) {
    factory->GetImage(SIZE{176, 136}, SIIGBF_BIGGERSIZEOK, &bitmap);
    factory->Release();
  }
  return bitmap;
}

bool InitializeGlobalSendDragPreview(IDataObject* data, HWND source,
    const std::wstring& text, const std::vector<std::wstring>& paths) {
  HBITMAP bitmap = GlobalSendContentDragBitmap(text, paths);
  const bool result = InitializeGlobalSendDragPreviewFromBitmap(data, source, bitmap);
  if (bitmap) DeleteObject(bitmap);
  return result;
}

bool InitializeGlobalSendDragPreviewFromBitmap(IDataObject* data, HWND source,
    HBITMAP bitmap) {
  IDragSourceHelper* helper = nullptr;
  if (FAILED(CoCreateInstance(CLSID_DragDropHelper, nullptr,
      CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&helper)))) return false;
  IDragSourceHelper2* extended = nullptr;
  if (SUCCEEDED(helper->QueryInterface(IID_PPV_ARGS(&extended)))) {
    extended->SetFlags(DSH_ALLOWDROPDESCRIPTIONTEXT);
    extended->Release();
  }
  HRESULT result = E_FAIL;
  if (bitmap) {
    BITMAP shape{};
    GetObjectW(bitmap, sizeof(shape), &shape);
    SHDRAGIMAGE image{};
    image.sizeDragImage = {shape.bmWidth, shape.bmHeight};
    image.ptOffset = {16, 16};
    image.hbmpDragImage = bitmap;
    image.crColorKey = CLR_NONE;
    result = helper->InitializeFromBitmap(&image, data);
  } else if (source) {
    POINT cursor{};
    GetCursorPos(&cursor);
    ScreenToClient(source, &cursor);
    result = helper->InitializeFromWindow(source, &cursor, data);
  }
  helper->Release();
  return SUCCEEDED(result);
}
