#include "drag_preview.h"
#include <shlobj.h>
#include <shobjidl.h>
#include <algorithm>
#include <cstdint>
#include <cstring>
#include <gdiplus.h>
#include <memory>
#include <atomic>
#pragma comment(lib, "gdiplus.lib")

namespace {
CLIPFORMAT TextDescriptorFormat() {
  return static_cast<CLIPFORMAT>(RegisterClipboardFormatW(CFSTR_FILEDESCRIPTORW));
}
CLIPFORMAT TextContentsFormat() {
  return static_cast<CLIPFORMAT>(RegisterClipboardFormatW(CFSTR_FILECONTENTS));
}

// SHCreateDataObject exposes AsyncCapability but this Shell implementation
// accepts SetAsyncMode(TRUE) without enabling it. Forward its entire data store
// (including private drag-image streams), add async ownership and expose text
// as a virtual TXT without replacing its ordinary Unicode representation.
// OLE uses the standard IDataObject proxy; no raw COM pointer crosses threads.
class AsyncShellData final : public IDataObject, public IDataObjectAsyncCapability {
 public:
  explicit AsyncShellData(IDataObject* shell, std::function<void(bool)> lease,
      std::vector<uint8_t> text_file)
      : shell_(shell), lease_(std::move(lease)), text_file_(std::move(text_file)) {
    if (lease_) lease_(true);
  }
  HRESULT STDMETHODCALLTYPE QueryInterface(REFIID iid, void** output) override {
    if (!output) return E_POINTER;
    *output = nullptr;
    if (iid == IID_IUnknown || iid == IID_IDataObject)
      *output = static_cast<IDataObject*>(this);
    else if (iid == IID_IDataObjectAsyncCapability)
      *output = static_cast<IDataObjectAsyncCapability*>(this);
    else return E_NOINTERFACE;
    AddRef(); return S_OK;
  }
  ULONG STDMETHODCALLTYPE AddRef() override { return ++references_; }
  ULONG STDMETHODCALLTYPE Release() override {
    const auto left = --references_;
    if (!left) delete this;
    return left;
  }
  HRESULT STDMETHODCALLTYPE GetData(FORMATETC* f, STGMEDIUM* m) override {
    if (!f || !m) return E_POINTER;
    if (!IsTextFileFormat(f)) return shell_->GetData(f, m);
    *m = {};
    const auto valid = QueryGetData(f);
    if (FAILED(valid)) return valid;
    if (f->cfFormat == TextContentsFormat()) {
      // A fresh stream per request: one consumer reading/closing it must not
      // change another consumer's offset, including async Shell copies.
      IStream* stream = nullptr;
      auto status = CreateStreamOnHGlobal(nullptr, TRUE, &stream);
      if (FAILED(status)) return status;
      ULONG written = 0;
      status = stream->Write(text_file_.data(), static_cast<ULONG>(text_file_.size()), &written);
      if (SUCCEEDED(status) && written != text_file_.size()) status = STG_E_WRITEFAULT;
      if (SUCCEEDED(status)) status = stream->Seek({}, STREAM_SEEK_SET, nullptr);
      if (FAILED(status)) { stream->Release(); return status; }
      m->tymed = TYMED_ISTREAM; m->pstm = stream;
      return S_OK;
    }
    m->hGlobal = GlobalAlloc(GMEM_MOVEABLE | GMEM_ZEROINIT, sizeof(FILEGROUPDESCRIPTORW));
    auto* group = m->hGlobal ? static_cast<FILEGROUPDESCRIPTORW*>(GlobalLock(m->hGlobal)) : nullptr;
    if (!group) {
      if (m->hGlobal) GlobalFree(m->hGlobal);
      *m = {}; return E_OUTOFMEMORY;
    }
    group->cItems = 1;
    auto& file = group->fgd[0];
    file.dwFlags = static_cast<DWORD>(FD_ATTRIBUTES | FD_FILESIZE | FD_UNICODE);
    file.dwFileAttributes = FILE_ATTRIBUTE_NORMAL;
    file.nFileSizeLow = static_cast<DWORD>(text_file_.size());
    wcscpy_s(file.cFileName, L"GlobalSend 文本.txt");
    GlobalUnlock(m->hGlobal); m->tymed = TYMED_HGLOBAL;
    return S_OK;
  }
  HRESULT STDMETHODCALLTYPE GetDataHere(FORMATETC* f, STGMEDIUM* m) override { return shell_->GetDataHere(f, m); }
  HRESULT STDMETHODCALLTYPE QueryGetData(FORMATETC* f) override {
    if (!f) return E_POINTER;
    if (!IsTextFileFormat(f)) return shell_->QueryGetData(f);
    if (f->dwAspect != DVASPECT_CONTENT) return DV_E_DVASPECT;
    const bool contents = f->cfFormat == TextContentsFormat();
    if (f->lindex != (contents ? 0 : -1)) return DV_E_LINDEX;
    return (f->tymed & (contents ? TYMED_ISTREAM : TYMED_HGLOBAL)) ? S_OK : DV_E_TYMED;
  }
  HRESULT STDMETHODCALLTYPE GetCanonicalFormatEtc(FORMATETC* f, FORMATETC* out) override { return shell_->GetCanonicalFormatEtc(f, out); }
  HRESULT STDMETHODCALLTYPE SetData(FORMATETC* f, STGMEDIUM* m, BOOL own) override { return shell_->SetData(f, m, own); }
  HRESULT STDMETHODCALLTYPE EnumFormatEtc(DWORD direction, IEnumFORMATETC** out) override {
    if (text_file_.empty() || direction != DATADIR_GET) return shell_->EnumFormatEtc(direction, out);
    std::vector<FORMATETC> formats;
    IEnumFORMATETC* existing = nullptr;
    auto status = shell_->EnumFormatEtc(direction, &existing);
    if (FAILED(status)) return status;
    FORMATETC item{};
    while (existing->Next(1, &item, nullptr) == S_OK) formats.push_back(item);
    existing->Release();
    // Keep Unicode text first for editors and GlobalSend's own drop target.
    formats.push_back({TextDescriptorFormat(), nullptr, DVASPECT_CONTENT, -1, TYMED_HGLOBAL});
    formats.push_back({TextContentsFormat(), nullptr, DVASPECT_CONTENT, 0, TYMED_ISTREAM});
    status = SHCreateStdEnumFmtEtc(static_cast<UINT>(formats.size()), formats.data(), out);
    for (const auto& format : formats) CoTaskMemFree(format.ptd);
    return status;
  }
  HRESULT STDMETHODCALLTYPE DAdvise(FORMATETC* f, DWORD flags, IAdviseSink* sink, DWORD* connection) override { return shell_->DAdvise(f, flags, sink, connection); }
  HRESULT STDMETHODCALLTYPE DUnadvise(DWORD connection) override { return shell_->DUnadvise(connection); }
  HRESULT STDMETHODCALLTYPE EnumDAdvise(IEnumSTATDATA** out) override { return shell_->EnumDAdvise(out); }
  HRESULT STDMETHODCALLTYPE SetAsyncMode(BOOL value) override { enabled_ = value != FALSE; return S_OK; }
  HRESULT STDMETHODCALLTYPE GetAsyncMode(BOOL* value) override { if (!value) return E_POINTER; *value = enabled_; return S_OK; }
  HRESULT STDMETHODCALLTYPE StartOperation(IBindCtx*) override {
    if (!running_.exchange(true)) AddRef();
    return S_OK;
  }
  HRESULT STDMETHODCALLTYPE InOperation(BOOL* value) override { if (!value) return E_POINTER; *value = running_; return S_OK; }
  HRESULT STDMETHODCALLTYPE EndOperation(HRESULT, IBindCtx*, DWORD) override {
    if (running_.exchange(false)) Release();
    return S_OK;
  }
 private:
  bool IsTextFileFormat(const FORMATETC* format) const {
    return !text_file_.empty() && (format->cfFormat == TextDescriptorFormat() ||
        format->cfFormat == TextContentsFormat());
  }
  ~AsyncShellData() { shell_->Release(); if (lease_) lease_(false); }
  std::atomic<ULONG> references_{1};
  std::atomic<bool> enabled_{true}, running_{false};
  IDataObject* shell_;
  std::function<void(bool)> lease_;
  std::vector<uint8_t> text_file_;
};

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
    const std::vector<uint8_t>& bytes, IDataObject** output, std::function<void(bool)> lease) {
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
  std::vector<uint8_t> text_file;
  if (format == CF_UNICODETEXT && bytes.size() >= sizeof(wchar_t)) {
    std::wstring text(bytes.size() / sizeof(wchar_t), L'\0');
    memcpy(text.data(), bytes.data(), text.size() * sizeof(wchar_t));
    text.resize(wcsnlen(text.data(), text.size()));
    const auto length = WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, text.data(),
        static_cast<int>(text.size()), nullptr, 0, nullptr, nullptr);
    if (length > 0) {
      // UTF-8 BOM lets Windows text editors reliably recognize Chinese/emoji.
      // This virtual file lives only in the IDataObject; no drag-cache file or
      // history item is created when the gesture is canceled.
      text_file = {0xef, 0xbb, 0xbf};
      text_file.resize(3 + length);
      WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, text.data(),
          static_cast<int>(text.size()), reinterpret_cast<char*>(text_file.data() + 3),
          length, nullptr, nullptr);
    }
  }
  *output = new AsyncShellData(data, std::move(lease), std::move(text_file));
  return S_OK;
}

HBITMAP GlobalSendTextDragBitmap(const std::wstring& text, GlobalSendDragPalette palette) {
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
    Gdiplus::SolidBrush white(Gdiplus::Color(palette.background));
    graphics.FillPath(&white, paper.get());
    Gdiplus::Pen border(Gdiplus::Color(palette.line), 1);
    graphics.DrawPath(&border, paper.get());
    auto preview = text.substr(0, 160);
    if (text.size() > preview.size()) preview += L"…";
    Gdiplus::FontFamily family(L"Microsoft YaHei UI");
    Gdiplus::Font body(&family, 14, Gdiplus::FontStyleRegular, Gdiplus::UnitPixel);
    Gdiplus::SolidBrush ink(Gdiplus::Color(palette.ink));
    Gdiplus::StringFormat format;
    format.SetTrimming(Gdiplus::StringTrimmingEllipsisCharacter);
    Gdiplus::RectF bounds(18, 15, 180, static_cast<float>(height - 53));
    graphics.DrawString(preview.c_str(), static_cast<int>(preview.size()), &body, bounds, &format, &ink);
    const float footer = static_cast<float>(height - 31);
    Gdiplus::Pen green(Gdiplus::Color(palette.accent), 1.4f);
    auto copy_back = Rounded(18, footer, 9, 11, 1.5f);
    auto copy_front = Rounded(21, footer + 3, 9, 11, 1.5f);
    graphics.DrawPath(&green, copy_back.get());
    graphics.DrawPath(&green, copy_front.get());
    Gdiplus::Font label(&family, 12, Gdiplus::FontStyleRegular, Gdiplus::UnitPixel);
    Gdiplus::SolidBrush accent(Gdiplus::Color(palette.accent));
    graphics.DrawString(L"复制", 2, &label, Gdiplus::PointF(37, footer - 1), &accent);
  }
  Gdiplus::GdiplusShutdown(token);
  return bitmap;
}

HBITMAP GlobalSendDragBitmapFromRgba(const std::vector<uint8_t>& rgba,
    int width, int height) {
  if (width <= 0 || height <= 0 || width > 2048 || height > 2048 ||
      rgba.size() != static_cast<size_t>(width) * height * 4) return nullptr;
  BITMAPINFO info{};
  info.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
  info.bmiHeader.biWidth = width;
  info.bmiHeader.biHeight = -height;
  info.bmiHeader.biPlanes = 1;
  info.bmiHeader.biBitCount = 32;
  info.bmiHeader.biCompression = BI_RGB;
  uint8_t* pixels = nullptr;
  HBITMAP bitmap = CreateDIBSection(nullptr, &info, DIB_RGB_COLORS,
      reinterpret_cast<void**>(&pixels), nullptr, 0);
  if (!bitmap) return nullptr;
  for (size_t i = 0; i < rgba.size(); i += 4) {
    pixels[i] = rgba[i + 2]; pixels[i + 1] = rgba[i + 1];
    pixels[i + 2] = rgba[i]; pixels[i + 3] = rgba[i + 3];
  }
  return bitmap;
}

HBITMAP GlobalSendContentDragBitmap(const std::wstring& text,
    const std::vector<std::wstring>& paths, GlobalSendDragPalette palette) {
  if (paths.empty()) return GlobalSendTextDragBitmap(text, palette);
  // A drag started before the first Flutter paint still gets a small card.
  // Asking a shell thumbnail provider here could synchronously load a huge
  // image or hydrate a remote file on the platform thread.
  const auto separator = paths.front().find_last_of(L"\\/");
  auto label = paths.front().substr(separator == std::wstring::npos ? 0 : separator + 1);
  if (paths.size() > 1) label += L"  +" + std::to_wstring(paths.size() - 1);
  return GlobalSendTextDragBitmap(label, palette);
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
    image.ptOffset = {shape.bmWidth / 2, shape.bmHeight / 2};
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
