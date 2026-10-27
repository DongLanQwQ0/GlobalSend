#ifndef GLOBALSEND_DRAG_PREVIEW_H_
#define GLOBALSEND_DRAG_PREVIEW_H_
#include <windows.h>
#include <objidl.h>
#include <cstdint>
#include <string>
#include <vector>

// Supplies the shell-owned drag image; COPY/no-drop cursors remain native.
bool InitializeGlobalSendDragPreview(IDataObject* data, HWND source,
    const std::wstring& text, const std::vector<std::wstring>& paths);
// The caller owns bitmap. Useful when shell thumbnail work was asynchronous.
bool InitializeGlobalSendDragPreviewFromBitmap(IDataObject* data, HWND source,
    HBITMAP bitmap);
HBITMAP GlobalSendTextDragBitmap(const std::wstring& text);
// Flutter's premultiplied RGBA card; no shell thumbnail/provider or file IO.
HBITMAP GlobalSendDragBitmapFromRgba(const std::vector<uint8_t>& rgba,
    int width, int height);
HBITMAP GlobalSendContentDragBitmap(const std::wstring& text,
    const std::vector<std::wstring>& paths);
// Shell IDataObject retains drag-helper private HGLOBAL and IStream formats.
// A payload-only IDataObject must not stand in for this cross-process store.
HRESULT CreateGlobalSendDragData(CLIPFORMAT format,
    const std::vector<uint8_t>& bytes, IDataObject** output);
#endif
