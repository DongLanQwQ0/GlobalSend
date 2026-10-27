#include "../runner/drag_preview.h"
#include "../runner/drop_target.h"
#include <shellapi.h>
#include <shlobj.h>
#include <cassert>
#include <cstring>
#include <iostream>

// Exercise the real Shell store and DragSourceHelper, not a mock that accepts
// only the public payload. The helper also uses a private IStream format.
int main() {
  assert(SUCCEEDED(OleInitialize(nullptr)));
  const std::wstring text = L"拖到窗口外仍有预览\n第二行🙂";
  std::vector<uint8_t> bytes((text.size() + 1) * sizeof(wchar_t));
  memcpy(bytes.data(), text.c_str(), bytes.size());
  IDataObject* data = nullptr;
  assert(SUCCEEDED(CreateGlobalSendDragData(CF_UNICODETEXT, bytes, &data)));
  assert(InitializeGlobalSendDragPreview(data, nullptr, text, {}));
  FORMATETC text_format{CF_UNICODETEXT, nullptr, DVASPECT_CONTENT, -1, TYMED_HGLOBAL};
  STGMEDIUM content{};
  assert(SUCCEEDED(data->GetData(&text_format, &content)));
  const auto* copied = static_cast<const wchar_t*>(GlobalLock(content.hGlobal));
  assert(copied && text == copied);
  GlobalUnlock(content.hGlobal);
  ReleaseStgMedium(&content);
  FORMATETC image_format{static_cast<CLIPFORMAT>(RegisterClipboardFormatW(L"DragImageBits")),
      nullptr, DVASPECT_CONTENT, -1, TYMED_HGLOBAL};
  assert(SUCCEEDED(data->GetData(&image_format, &content)));
  assert(GlobalSize(content.hGlobal) > 216 * 132 * 4);
  ReleaseStgMedium(&content);
  FORMATETC stream_format{static_cast<CLIPFORMAT>(RegisterClipboardFormatW(L"GlobalSend.TestStream")),
      nullptr, DVASPECT_CONTENT, -1, TYMED_ISTREAM};
  IStream* stream = nullptr;
  assert(SUCCEEDED(CreateStreamOnHGlobal(nullptr, TRUE, &stream)));
  STGMEDIUM private_medium{};
  private_medium.tymed = TYMED_ISTREAM;
  private_medium.pstm = stream;
  assert(SUCCEEDED(data->SetData(&stream_format, &private_medium, TRUE)));
  assert(SUCCEEDED(data->GetData(&stream_format, &content)));
  assert(content.tymed == TYMED_ISTREAM && content.pstm);
  ReleaseStgMedium(&content);
  HWND target_window = CreateWindowExW(0, L"STATIC", L"Hidden native drag image target",
      WS_POPUP, 0, 0, 400, 200, nullptr, nullptr, GetModuleHandleW(nullptr), nullptr);
  assert(target_window);
  bool copied_back = false;
  IDropTarget* target = CreateGlobalSendDropTarget({[](bool) {},
      [&](GlobalSendDroppedContent value) { copied_back = value.text == text; },
      [] { return true; }, [](POINTL point) { return point.x < 200; }}, target_window);
  DWORD effect = DROPEFFECT_COPY;
  assert(SUCCEEDED(target->DragEnter(data, 0, POINTL{30, 40}, &effect)) && effect == DROPEFFECT_COPY);
  effect = DROPEFFECT_COPY;
  assert(SUCCEEDED(target->DragOver(0, POINTL{230, 40}, &effect)) && effect == DROPEFFECT_NONE);
  assert(SUCCEEDED(target->DragLeave()));
  effect = DROPEFFECT_COPY;
  assert(SUCCEEDED(target->DragEnter(data, 0, POINTL{30, 40}, &effect)));
  effect = DROPEFFECT_COPY;
  const auto returned_drop = target->Drop(data, 0, POINTL{30, 40}, &effect);
  if (FAILED(returned_drop) || effect != DROPEFFECT_COPY) {
    for (auto type : {CF_HDROP, CF_UNICODETEXT}) {
      FORMATETC check{static_cast<CLIPFORMAT>(type), nullptr, DVASPECT_CONTENT, -1, TYMED_HGLOBAL};
      STGMEDIUM value{};
      const auto status = data->GetData(&check, &value);
      std::cerr << "format=" << type << " query=" << data->QueryGetData(&check) << " hr=" << status << " medium=" << value.tymed;
      if (value.tymed == TYMED_HGLOBAL && value.hGlobal) {
        std::cerr << " bytes=" << GlobalSize(value.hGlobal);
        if (type == CF_HDROP) std::cerr << " paths=" << DragQueryFileW(static_cast<HDROP>(value.hGlobal), 0xffffffff, nullptr, 0);
      }
      std::cerr << '\n';
      if (SUCCEEDED(status)) ReleaseStgMedium(&value);
    }
    std::cerr << "returned drop effect=" << effect << '\n';
    return 1;
  }
  assert(copied_back);
  target->Release();
  DestroyWindow(target_window);
  data->Release();

  std::wstring names = L"F:\\文件夹\\图 片.png";
  names.push_back(L'\0');
  names.append(L"F:\\文件夹");
  names.push_back(L'\0');
  names.push_back(L'\0');
  DROPFILES header{};
  header.pFiles = sizeof(header);
  header.fWide = TRUE;
  bytes.resize(sizeof(header) + names.size() * sizeof(wchar_t));
  memcpy(bytes.data(), &header, sizeof(header));
  memcpy(bytes.data() + sizeof(header), names.data(), names.size() * sizeof(wchar_t));
  assert(SUCCEEDED(CreateGlobalSendDragData(CF_HDROP, bytes, &data)));
  FORMATETC files_format{CF_HDROP, nullptr, DVASPECT_CONTENT, -1, TYMED_HGLOBAL};
  assert(SUCCEEDED(data->GetData(&files_format, &content)));
  assert(DragQueryFileW(static_cast<HDROP>(content.hGlobal), 0xffffffff, nullptr, 0) == 2);
  wchar_t name[MAX_PATH]{};
  DragQueryFileW(static_cast<HDROP>(content.hGlobal), 1, name, MAX_PATH);
  assert(std::wstring(name) == L"F:\\文件夹");
  ReleaseStgMedium(&content);
  data->Release();
  OleUninitialize();
  std::cout << "PASS real Shell IDataObject and target helper: Unicode, DragImageBits, private IStream, out/in queue return, multi-file CF_HDROP\n";
}
