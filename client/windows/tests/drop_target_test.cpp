#include "../runner/drop_target.h"
#include "../runner/queue_drop_region.h"
#include <shellapi.h>
#include <shlobj.h>
#include <cassert>
#include <cstring>
#include <iostream>
#include <map>

namespace {
class MediumOwner final : public IUnknown {
 public:
  MediumOwner(HGLOBAL memory, int* releases) : memory_(memory), releases_(releases) {}
  HRESULT STDMETHODCALLTYPE QueryInterface(REFIID id, void** value) override {
    if (!value) return E_POINTER;
    *value = nullptr;
    if (id != IID_IUnknown) return E_NOINTERFACE;
    *value = this; AddRef(); return S_OK;
  }
  ULONG STDMETHODCALLTYPE AddRef() override { return ++references_; }
  ULONG STDMETHODCALLTYPE Release() override {
    const auto remaining = --references_;
    if (!remaining) { GlobalFree(memory_); ++*releases_; delete this; }
    return remaining;
  }
 private:
  ULONG references_ = 1;
  HGLOBAL memory_;
  int* releases_;
};

class Data final : public IDataObject {
 public:
  std::map<CLIPFORMAT, std::vector<uint8_t>> formats;
  int releases = 0;
  HRESULT STDMETHODCALLTYPE QueryInterface(REFIID id, void** value) override {
    if (!value) return E_POINTER;
    *value = nullptr;
    if (id != IID_IUnknown && id != IID_IDataObject) return E_NOINTERFACE;
    *value = static_cast<IDataObject*>(this); AddRef(); return S_OK;
  }
  ULONG STDMETHODCALLTYPE AddRef() override { return ++references_; }
  ULONG STDMETHODCALLTYPE Release() override { const auto remaining = --references_; if (!remaining) delete this; return remaining; }
  HRESULT STDMETHODCALLTYPE QueryGetData(FORMATETC* format) override {
    return format && formats.count(format->cfFormat) && format->dwAspect == DVASPECT_CONTENT &&
        (format->tymed & TYMED_HGLOBAL) ? S_OK : DV_E_FORMATETC;
  }
  HRESULT STDMETHODCALLTYPE GetData(FORMATETC* format, STGMEDIUM* medium) override {
    if (QueryGetData(format) != S_OK) return DV_E_FORMATETC;
    const auto& bytes = formats.at(format->cfFormat);
    HGLOBAL memory = GlobalAlloc(GMEM_MOVEABLE, bytes.size());
    assert(memory);
    void* destination = GlobalLock(memory); assert(destination);
    memcpy(destination, bytes.data(), bytes.size()); GlobalUnlock(memory);
    medium->tymed = TYMED_HGLOBAL;
    medium->hGlobal = memory;
    medium->pUnkForRelease = new MediumOwner(memory, &releases);
    return S_OK;
  }
  HRESULT STDMETHODCALLTYPE GetDataHere(FORMATETC*, STGMEDIUM*) override { return E_NOTIMPL; }
  HRESULT STDMETHODCALLTYPE GetCanonicalFormatEtc(FORMATETC*, FORMATETC*) override { return E_NOTIMPL; }
  HRESULT STDMETHODCALLTYPE SetData(FORMATETC*, STGMEDIUM*, BOOL) override { return E_NOTIMPL; }
  HRESULT STDMETHODCALLTYPE EnumFormatEtc(DWORD, IEnumFORMATETC**) override { return E_NOTIMPL; }
  HRESULT STDMETHODCALLTYPE DAdvise(FORMATETC*, DWORD, IAdviseSink*, DWORD*) override { return OLE_E_ADVISENOTSUPPORTED; }
  HRESULT STDMETHODCALLTYPE DUnadvise(DWORD) override { return OLE_E_ADVISENOTSUPPORTED; }
  HRESULT STDMETHODCALLTYPE EnumDAdvise(IEnumSTATDATA**) override { return OLE_E_ADVISENOTSUPPORTED; }
 private:
  ULONG references_ = 1;
};

std::vector<uint8_t> Text(const std::wstring& text) {
  std::vector<uint8_t> bytes((text.size() + 1) * sizeof(wchar_t));
  memcpy(bytes.data(), text.c_str(), bytes.size());
  return bytes;
}

std::vector<uint8_t> Files(const std::vector<std::wstring>& paths) {
  std::wstring names;
  for (const auto& path : paths) { names.append(path); names.push_back(L'\0'); }
  names.push_back(L'\0');
  DROPFILES header{}; header.pFiles = sizeof(DROPFILES); header.fWide = TRUE;
  std::vector<uint8_t> bytes(sizeof(header) + names.size() * sizeof(wchar_t));
  memcpy(bytes.data(), &header, sizeof(header));
  memcpy(bytes.data() + sizeof(header), names.data(), names.size() * sizeof(wchar_t));
  return bytes;
}
}  // namespace

int main() {
  GlobalSendQueueDropRegion region{true, RECT{20, 40, 220, 240}, SIZE{950, 650}};
  assert(region.Contains(POINT{30, 60}, SIZE{950, 650}));
  assert(!region.Contains(POINT{230, 60}, SIZE{950, 650}));
  assert(!region.Contains(POINT{30, 60}, SIZE{1000, 650}));
  region.enabled = false;
  assert(!region.Contains(POINT{30, 60}, SIZE{950, 650}));
  std::wstring long_path = L"\\\\?\\F:\\长目录\\";
  for (int i = 0; i < 16; ++i) long_path += L"abcdefghijklmnopqrst\\";
  long_path += L"空文件.bin";
  const std::vector<std::wstring> paths{L"F:\\测试\\中文文件.txt", long_path};
  auto* data = new Data();
  data->formats[CF_HDROP] = Files(paths);
  data->formats[CF_UNICODETEXT] = Text(L"同一文件的文本表示，不应重复添加");
  GlobalSendDroppedContent decoded;
  assert(ReadGlobalSendDrop(data, &decoded));
  assert(decoded.paths == paths && decoded.text.empty());
  assert(data->releases == 1);

  std::vector<bool> hover;
  std::vector<GlobalSendDroppedContent> dropped;
  bool outgoing = false;
  bool queue_visible = true;
  IDropTarget* target = CreateGlobalSendDropTarget({
      [&](bool value) { hover.push_back(value); },
      [&](GlobalSendDroppedContent value) { dropped.push_back(std::move(value)); },
      [&] { return outgoing; },
      [&](POINTL point) { return queue_visible && point.x >= 20 && point.x < 220 && point.y >= 40 && point.y < 240; }});
  DWORD effect = DROPEFFECT_COPY | DROPEFFECT_MOVE;
  assert(target->DragEnter(data, 0, {}, &effect) == S_OK && effect == DROPEFFECT_COPY);
  assert(hover == std::vector<bool>{true});
  effect = DROPEFFECT_MOVE;
  assert(target->DragOver(MK_SHIFT, {}, &effect) == S_OK && effect == DROPEFFECT_NONE);
  assert((hover == std::vector<bool>{true, false}));
  effect = DROPEFFECT_COPY;
  target->DragOver(0, {}, &effect);
  effect = DROPEFFECT_COPY | DROPEFFECT_MOVE;
  assert(target->Drop(data, 0, {}, &effect) == S_OK && effect == DROPEFFECT_COPY);
  assert(dropped.size() == 1 && dropped.back().paths == paths && !hover.back());
  assert(data->releases == 2);

  outgoing = true;
  effect = DROPEFFECT_COPY;
  target->DragEnter(data, 0, {}, &effect);
  assert(effect == DROPEFFECT_NONE);
  effect = DROPEFFECT_COPY;
  target->Drop(data, 0, {}, &effect);
  assert(effect == DROPEFFECT_NONE && dropped.size() == 1);
  assert(data->releases == 2);
  // Returning native export is valid only inside the visible send queue.
  effect = DROPEFFECT_COPY;
  target->DragEnter(data, 0, POINTL{30, 60}, &effect);
  assert(effect == DROPEFFECT_COPY && hover.back());
  effect = DROPEFFECT_COPY;
  target->DragOver(0, POINTL{230, 60}, &effect);
  assert(effect == DROPEFFECT_NONE && !hover.back());
  effect = DROPEFFECT_COPY;
  target->DragOver(0, POINTL{30, 60}, &effect);
  assert(effect == DROPEFFECT_COPY && hover.back());
  effect = DROPEFFECT_COPY;
  target->Drop(data, 0, POINTL{30, 60}, &effect);
  assert(effect == DROPEFFECT_COPY && dropped.size() == 2 && data->releases == 3);
  queue_visible = false;
  effect = DROPEFFECT_COPY;
  target->DragEnter(data, 0, POINTL{30, 60}, &effect);
  assert(effect == DROPEFFECT_NONE);
  target->DragLeave();
  queue_visible = true;
  outgoing = false;

  auto* text = new Data();
  text->formats[CF_UNICODETEXT] = Text(L"第一段\r\nUnicode 纯文字");
  effect = DROPEFFECT_COPY;
  target->DragEnter(text, 0, {}, &effect);
  assert(effect == DROPEFFECT_COPY && hover.back());
  effect = DROPEFFECT_COPY;
  target->Drop(text, 0, {}, &effect);
  assert(effect == DROPEFFECT_COPY && !hover.back());
  assert(dropped.size() == 3 && dropped.back().text == L"第一段\r\nUnicode 纯文字");
  assert(dropped.back().paths.empty() && text->releases == 1);

  auto* unsupported = new Data();
  effect = DROPEFFECT_COPY;
  target->DragEnter(unsupported, 0, {}, &effect);
  assert(effect == DROPEFFECT_NONE);
  target->DragLeave();
  effect = DROPEFFECT_COPY;
  target->Drop(unsupported, 0, {}, &effect);
  assert(effect == DROPEFFECT_NONE && dropped.size() == 3);

  auto* too_many = new Data();
  too_many->formats[CF_HDROP] = Files(std::vector<std::wstring>(33, L"F:\\file.txt"));
  effect = DROPEFFECT_COPY;
  target->Drop(too_many, 0, {}, &effect);
  assert(effect == DROPEFFECT_NONE && dropped.size() == 4);
  assert(!dropped.back().error.empty() && too_many->releases == 1);

  IUnknown* identity = nullptr;
  assert(target->QueryInterface(IID_IUnknown, reinterpret_cast<void**>(&identity)) == S_OK);
  assert(identity->Release() == 1);
  assert(target->Release() == 0);
  data->Release(); text->Release(); unsupported->Release(); too_many->Release();
  std::cout << "PASS: Windows OLE import, Unicode paths, COPY-only, local out/in queue targeting, external whole-window input, stale bounds and media release\n";
}
