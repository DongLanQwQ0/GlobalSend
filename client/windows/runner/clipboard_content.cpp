#include "clipboard_content.h"
#include <shellapi.h>
#include <cstring>
#include <cstdint>

namespace {
UINT PngFormat() {
  const UINT png = RegisterClipboardFormatW(L"PNG");
  return IsClipboardFormatAvailable(png) ? png : RegisterClipboardFormatW(L"image/png");
}
bool WriteImage(const std::wstring& path, const void* header, DWORD header_size,
    const void* data, DWORD size) {
  const HANDLE file = CreateFileW(path.c_str(), GENERIC_WRITE, 0, nullptr,
      CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
  if (file == INVALID_HANDLE_VALUE) return false;
  DWORD count = 0;
  const bool success = (!header_size ||
      (WriteFile(file, header, header_size, &count, nullptr) && count == header_size)) &&
      WriteFile(file, data, size, &count, nullptr) && count == size;
  CloseHandle(file);
  if (!success) DeleteFileW(path.c_str());
  return success;
}
bool SavePng(const std::wstring& path) {
  const HANDLE memory = GetClipboardData(PngFormat());
  if (!memory) return false;
  const SIZE_T length = GlobalSize(memory);
  const void* data = GlobalLock(memory);
  if (!data) return false;
  const bool success = WriteImage(path, nullptr, 0, data, static_cast<DWORD>(length));
  GlobalUnlock(memory);
  return success;
}
bool SaveDib(const std::wstring& path) {
  const HANDLE memory = GetClipboardData(IsClipboardFormatAvailable(CF_DIBV5) ? CF_DIBV5 : CF_DIB);
  if (!memory) return false;
  const SIZE_T length = GlobalSize(memory);
  const auto* dib = static_cast<const uint8_t*>(GlobalLock(memory));
  if (!dib) return false;
  bool written = false;
  if (length >= sizeof(BITMAPINFOHEADER)) {
    const auto* info = reinterpret_cast<const BITMAPINFOHEADER*>(dib);
    const DWORD palette = info->biClrUsed ? info->biClrUsed : info->biBitCount <= 8 ? 1u << info->biBitCount : 0;
    const DWORD masks = info->biSize == sizeof(BITMAPINFOHEADER) && info->biCompression == BI_BITFIELDS ? 3 * sizeof(DWORD) : 0;
    BITMAPFILEHEADER header{};
    header.bfType = 0x4d42;
    header.bfSize = static_cast<DWORD>(sizeof(header) + length);
    header.bfOffBits = sizeof(header) + info->biSize + masks + palette * sizeof(RGBQUAD);
    written = WriteImage(path, &header, sizeof(header), dib, static_cast<DWORD>(length));
  }
  GlobalUnlock(memory);
  return written;
}
bool SaveBitmap(const std::wstring& path) {
  const auto bitmap = static_cast<HBITMAP>(GetClipboardData(CF_BITMAP));
  BITMAP source{};
  if (!bitmap || !GetObjectW(bitmap, sizeof(source), &source)) return false;
  BITMAPINFO info{};
  info.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
  info.bmiHeader.biWidth = source.bmWidth;
  info.bmiHeader.biHeight = source.bmHeight;
  info.bmiHeader.biPlanes = 1;
  info.bmiHeader.biBitCount = 32;
  info.bmiHeader.biCompression = BI_RGB;
  std::vector<uint8_t> pixels(static_cast<size_t>(source.bmWidth) * source.bmHeight * 4);
  HDC dc = GetDC(nullptr);
  const int rows = GetDIBits(dc, bitmap, 0, source.bmHeight, pixels.data(), &info, DIB_RGB_COLORS);
  ReleaseDC(nullptr, dc);
  if (rows != source.bmHeight) return false;
  BITMAPFILEHEADER header{};
  header.bfType = 0x4d42;
  header.bfOffBits = sizeof(header) + sizeof(BITMAPINFOHEADER);
  header.bfSize = header.bfOffBits + static_cast<DWORD>(pixels.size());
  std::vector<uint8_t> body(sizeof(BITMAPINFOHEADER) + pixels.size());
  memcpy(body.data(), &info.bmiHeader, sizeof(BITMAPINFOHEADER));
  memcpy(body.data() + sizeof(BITMAPINFOHEADER), pixels.data(), pixels.size());
  return WriteImage(path, &header, sizeof(header), body.data(), static_cast<DWORD>(body.size()));
}
std::wstring Extension(std::wstring path, const wchar_t* extension) {
  const auto dot = path.find_last_of(L'.'), slash = path.find_last_of(L"/\\");
  if (dot != std::wstring::npos && (slash == std::wstring::npos || dot > slash)) path.resize(dot);
  return path + extension;
}
}  // namespace

std::string GlobalSendClipboardKind() {
  if (IsClipboardFormatAvailable(CF_HDROP)) return "files";
  if (IsClipboardFormatAvailable(PngFormat()) || IsClipboardFormatAvailable(CF_DIBV5) ||
      IsClipboardFormatAvailable(CF_DIB) || IsClipboardFormatAvailable(CF_BITMAP)) return "image";
  return IsClipboardFormatAvailable(CF_UNICODETEXT) ? "text" : "empty";
}

GlobalSendClipboardContent ReadGlobalSendClipboard(HWND owner, const std::wstring& bitmap_path) {
  GlobalSendClipboardContent content;
  if (!OpenClipboard(owner)) { content.error = "剪贴板正被占用，请重试"; return content; }
  const auto kind = GlobalSendClipboardKind();
  if (kind == "files") {
    const auto drop = static_cast<HDROP>(GetClipboardData(CF_HDROP));
    const UINT count = DragQueryFileW(drop, 0xffffffff, nullptr, 0);
    for (UINT i = 0; i < count; ++i) {
      std::wstring path(DragQueryFileW(drop, i, nullptr, 0) + 1, L'\0');
      DragQueryFileW(drop, i, path.data(), static_cast<UINT>(path.size()));
      path.resize(wcslen(path.c_str()));
      content.paths.push_back(std::move(path));
    }
  } else if (kind == "image") {
    auto path = Extension(bitmap_path, L".png");
    bool saved = !bitmap_path.empty() && IsClipboardFormatAvailable(PngFormat()) && SavePng(path);
    if (!saved && !bitmap_path.empty()) {
      path = Extension(bitmap_path, L".bmp");
      saved = (IsClipboardFormatAvailable(CF_DIBV5) || IsClipboardFormatAvailable(CF_DIB))
          ? SaveDib(path) : SaveBitmap(path);
    }
    if (saved) { content.paths.push_back(path); content.temporary_paths.push_back(path); }
    else content.error = "无法读取剪贴板图片";
  } else if (kind == "text") {
    const HANDLE memory = GetClipboardData(CF_UNICODETEXT);
    const auto* text = static_cast<const wchar_t*>(GlobalLock(memory));
    if (text) {
      content.texts.emplace_back(text, wcsnlen(text, GlobalSize(memory) / sizeof(wchar_t)));
      GlobalUnlock(memory);
    }
  }
  CloseClipboard();
  return content;
}
