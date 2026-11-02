#ifndef GLOBALSEND_DRAG_PREVIEW_H_
#define GLOBALSEND_DRAG_PREVIEW_H_
#include <windows.h>
#include <objidl.h>
#include <cstdint>
#include <string>
#include <vector>
#include <functional>

// Supplies the shell-owned drag image; COPY/no-drop cursors remain native.
bool InitializeGlobalSendDragPreview(IDataObject* data, HWND source,
    const std::wstring& text, const std::vector<std::wstring>& paths);
// The caller owns bitmap. Useful when shell thumbnail work was asynchronous.
bool InitializeGlobalSendDragPreviewFromBitmap(IDataObject* data, HWND source,
    HBITMAP bitmap);
struct GlobalSendDragPalette {
  uint32_t background = 0xf8fafdfa;
  uint32_t ink = 0xff202923;
  uint32_t accent = 0xff176b50;
  uint32_t line = 0x96dbe5dc;
};
HBITMAP GlobalSendTextDragBitmap(const std::wstring& text,
    GlobalSendDragPalette palette = {});
// Flutter's premultiplied RGBA card; no shell thumbnail/provider or file IO.
HBITMAP GlobalSendDragBitmapFromRgba(const std::vector<uint8_t>& rgba,
    int width, int height);
HBITMAP GlobalSendContentDragBitmap(const std::wstring& text,
    const std::vector<std::wstring>& paths, GlobalSendDragPalette palette = {});
// Shell IDataObject retains drag-helper private HGLOBAL and IStream formats.
// A payload-only IDataObject must not stand in for this cross-process store.
HRESULT CreateGlobalSendDragData(CLIPFORMAT format,
    const std::vector<uint8_t>& bytes, IDataObject** output,
    std::function<void(bool)> lease = {});
#endif
