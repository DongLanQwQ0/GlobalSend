#include "drop_target.h"

#include <shellapi.h>
#include <shobjidl.h>
#include <shlobj.h>
#include <utility>

namespace {
FORMATETC Format(CLIPFORMAT type) {
  return FORMATETC{type, nullptr, DVASPECT_CONTENT, -1, TYMED_HGLOBAL};
}

bool Supports(IDataObject* data, CLIPFORMAT type) {
  auto format = Format(type);
  // Shell IDataObject returns S_FALSE for an absent format; SUCCEEDED would
  // incorrectly prefer its nonexistent CF_HDROP over valid Unicode text.
  return data && data->QueryGetData(&format) == S_OK;
}

class OwnedMedium {
 public:
  STGMEDIUM value{};
  ~OwnedMedium() { if (value.tymed != TYMED_NULL) ReleaseStgMedium(&value); }
};

class DropTarget final : public IDropTarget {
 public:
  explicit DropTarget(GlobalSendDropCallbacks callbacks, HWND window)
      : callbacks_(std::move(callbacks)), window_(window) {
    CoCreateInstance(CLSID_DragDropHelper, nullptr, CLSCTX_INPROC_SERVER,
        IID_PPV_ARGS(&image_));
  }
  ~DropTarget() { if (image_) image_->Release(); }

  HRESULT STDMETHODCALLTYPE QueryInterface(REFIID id, void** object) override {
    if (!object) return E_POINTER;
    *object = nullptr;
    if (id != IID_IUnknown && id != IID_IDropTarget) return E_NOINTERFACE;
    *object = static_cast<IDropTarget*>(this);
    AddRef();
    return S_OK;
  }
  ULONG STDMETHODCALLTYPE AddRef() override { return InterlockedIncrement(&references_); }
  ULONG STDMETHODCALLTYPE Release() override {
    const auto count = InterlockedDecrement(&references_);
    if (!count) delete this;
    return count;
  }
  HRESULT STDMETHODCALLTYPE DragEnter(IDataObject* data, DWORD, POINTL point, DWORD* effect) override {
    if (!effect) return E_POINTER;
    supported_ = Supports(data, CF_HDROP) || Supports(data, CF_UNICODETEXT);
    SetEffect(point, effect);
    POINT screen{point.x, point.y};
    if (image_) image_->DragEnter(window_, data, &screen, *effect);
    return S_OK;
  }
  HRESULT STDMETHODCALLTYPE DragOver(DWORD, POINTL point, DWORD* effect) override {
    if (!effect) return E_POINTER;
    SetEffect(point, effect);
    POINT screen{point.x, point.y};
    if (image_) image_->DragOver(&screen, *effect);
    return S_OK;
  }
  HRESULT STDMETHODCALLTYPE DragLeave() override {
    supported_ = false;
    Hover(false);
    if (image_) image_->DragLeave();
    return S_OK;
  }
  HRESULT STDMETHODCALLTYPE Drop(IDataObject* data, DWORD, POINTL point, DWORD* effect) override {
    if (!effect) return E_POINTER;
    const bool copy = (*effect & DROPEFFECT_COPY) != 0 && Allows(point);
    *effect = DROPEFFECT_NONE;
    supported_ = false;
    Hover(false);
    POINT screen{point.x, point.y};
    if (!copy) { if (image_) image_->Drop(data, &screen, *effect); return S_OK; }
    GlobalSendDroppedContent content;
    const bool imported = ReadGlobalSendDrop(data, &content);
    content.screen_point = point;
    content.has_screen_point = true;
    if (imported || !content.error.empty()) callbacks_.drop(std::move(content));
    if (imported) *effect = DROPEFFECT_COPY;
    if (image_) image_->Drop(data, &screen, *effect);
    return S_OK;
  }

 private:
  bool Outgoing() const { return callbacks_.outgoing_drag && callbacks_.outgoing_drag(); }
  bool Allows(POINTL point) const {
    return !Outgoing() || (callbacks_.local_drop_at && callbacks_.local_drop_at(point));
  }
  void Hover(bool active) {
    if (active_ == active) return;
    active_ = active;
    callbacks_.hover(active);
  }
  void SetEffect(POINTL point, DWORD* effect) {
    const bool copy = supported_ && Allows(point) && (*effect & DROPEFFECT_COPY) != 0;
    *effect = copy ? DROPEFFECT_COPY : DROPEFFECT_NONE;
    Hover(copy);
  }
  LONG references_ = 1;
  bool supported_ = false;
  bool active_ = false;
  GlobalSendDropCallbacks callbacks_;
  HWND window_ = nullptr;
  IDropTargetHelper* image_ = nullptr;
};
}  // namespace

bool ReadGlobalSendDrop(IDataObject* data, GlobalSendDroppedContent* content) {
  if (!data || !content) return false;
  *content = {};
  const bool files = Supports(data, CF_HDROP);
  auto format = Format(files ? CF_HDROP : CF_UNICODETEXT);
  if (!files && !Supports(data, CF_UNICODETEXT)) return false;
  OwnedMedium medium;
  if (FAILED(data->GetData(&format, &medium.value)) || medium.value.tymed != TYMED_HGLOBAL ||
      !medium.value.hGlobal) {
    content->error = "Windows could not read the dropped content";
    return false;
  }
  if (files) {
    auto handle = reinterpret_cast<HDROP>(medium.value.hGlobal);
    const UINT count = DragQueryFileW(handle, 0xffffffff, nullptr, 0);
    if (count > 32) {
      content->error = "一次最多添加 32 个文件";
      return false;
    }
    for (UINT i = 0; i < count; ++i) {
      const UINT length = DragQueryFileW(handle, i, nullptr, 0);
      std::wstring path(static_cast<size_t>(length) + 1, L'\0');
      if (!length || DragQueryFileW(handle, i, path.data(), length + 1) != length) {
        content->error = "Windows could not read the dropped file path";
        content->paths.clear();
        return false;
      }
      path.resize(length);
      content->paths.push_back(std::move(path));
    }
    return !content->paths.empty();
  }
  const SIZE_T bytes = GlobalSize(medium.value.hGlobal);
  const auto* text = static_cast<const wchar_t*>(GlobalLock(medium.value.hGlobal));
  if (!text) return false;
  const size_t capacity = bytes / sizeof(wchar_t);
  const size_t length = wcsnlen(text, capacity);
  if (length <= 100000) content->text.assign(text, length);
  else content->error = "文字最多 100000 字";
  GlobalUnlock(medium.value.hGlobal);
  return !content->text.empty();
}

IDropTarget* CreateGlobalSendDropTarget(GlobalSendDropCallbacks callbacks, HWND window) {
  return new DropTarget(std::move(callbacks), window);
}
