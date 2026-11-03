#include "../runner/drag_preview.h"
#include "../runner/drop_target.h"
#include <shlobj.h>
#include <shobjidl.h>
#include <cassert>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <iostream>

// Production OLE data object and the actual Shell folder drop handler. No
// desktop/Explorer UI, system clipboard, user files or physical input involved.
int wmain(int argc, wchar_t** argv) {
  assert(argc == 2 && SUCCEEDED(OleInitialize(nullptr)));
  const auto root = std::filesystem::absolute(argv[1]);
  assert(!std::filesystem::exists(root));
  std::filesystem::create_directories(root);
  const std::wstring text = L"中文拖放🙂\nhttps://example.test/a?b=1\n第二行\r\n";
  std::vector<uint8_t> bytes((text.size() + 1) * sizeof(wchar_t));
  memcpy(bytes.data(), text.c_str(), bytes.size());
  IDataObject* data = nullptr;
  assert(SUCCEEDED(CreateGlobalSendDragData(CF_UNICODETEXT, bytes, &data)));
  assert(InitializeGlobalSendDragPreview(data, nullptr, text, {}));
  FORMATETC descriptor{static_cast<CLIPFORMAT>(RegisterClipboardFormatW(CFSTR_FILEDESCRIPTORW)),
      nullptr, DVASPECT_CONTENT, -1, TYMED_HGLOBAL};
  FORMATETC contents{static_cast<CLIPFORMAT>(RegisterClipboardFormatW(CFSTR_FILECONTENTS)),
      nullptr, DVASPECT_CONTENT, 0, TYMED_ISTREAM};
  assert(data->QueryGetData(&descriptor) == S_OK && data->QueryGetData(&contents) == S_OK);
  STGMEDIUM metadata{};
  assert(SUCCEEDED(data->GetData(&descriptor, &metadata)));
  const auto* group = static_cast<const FILEGROUPDESCRIPTORW*>(GlobalLock(metadata.hGlobal));
  assert(group && group->cItems == 1);
  const std::wstring name = group->fgd[0].cFileName;
  assert(name == L"GlobalSend 文本.txt");
  const auto size = group->fgd[0].nFileSizeLow;
  GlobalUnlock(metadata.hGlobal); ReleaseStgMedium(&metadata);
  std::string expected = "\xef\xbb\xbf";
  const auto length = WideCharToMultiByte(CP_UTF8, 0, text.data(), static_cast<int>(text.size()), nullptr, 0, nullptr, nullptr);
  expected.resize(3 + length);
  WideCharToMultiByte(CP_UTF8, 0, text.data(), static_cast<int>(text.size()), expected.data() + 3, length, nullptr, nullptr);
  assert(size == expected.size());

  IEnumFORMATETC* formats = nullptr;
  assert(SUCCEEDED(data->EnumFormatEtc(DATADIR_GET, &formats)));
  FORMATETC entry{}; bool has_text = false, has_file = false, has_contents = false;
  while (formats->Next(1, &entry, nullptr) == S_OK) {
    has_text |= entry.cfFormat == CF_UNICODETEXT;
    has_file |= entry.cfFormat == descriptor.cfFormat;
    has_contents |= entry.cfFormat == contents.cfFormat && entry.lindex == 0;
    CoTaskMemFree(entry.ptd);
  }
  formats->Release(); assert(has_text && has_file && has_contents);
  FORMATETC not_a_path{CF_HDROP, nullptr, DVASPECT_CONTENT, -1, TYMED_HGLOBAL};
  assert(data->QueryGetData(&not_a_path) != S_OK);
  GlobalSendDroppedContent imported;
  assert(ReadGlobalSendDrop(data, &imported) && imported.text == text && imported.paths.empty());
  auto invalid = contents; invalid.lindex = 1;
  assert(data->QueryGetData(&invalid) == DV_E_LINDEX);

  // Independently opened streams begin at byte zero, even after a consumer
  // reads the previous stream through EOF.
  for (int read = 0; read < 2; ++read) {
    STGMEDIUM medium{};
    assert(SUCCEEDED(data->GetData(&contents, &medium)) && medium.tymed == TYMED_ISTREAM);
    std::string value(expected.size() + 1, '\0'); ULONG count = 0;
    assert(SUCCEEDED(medium.pstm->Read(value.data(), static_cast<ULONG>(value.size()), &count)));
    value.resize(count); assert(value == expected);
    ReleaseStgMedium(&medium);
  }
  // Actual Explorer/Desktop copy implementation, bound to a project-only
  // directory. Shell chooses FILEDESCRIPTOR/FILECONTENTS from the same object.
  IShellItem* folder = nullptr;
  assert(SUCCEEDED(SHCreateItemFromParsingName(root.c_str(), nullptr, IID_PPV_ARGS(&folder))));
  IDropTarget* target = nullptr;
  assert(SUCCEEDED(folder->BindToHandler(nullptr, BHID_SFUIObject, IID_PPV_ARGS(&target))));
  POINTL point{}; DWORD effect = DROPEFFECT_COPY;
  assert(SUCCEEDED(target->DragEnter(data, MK_LBUTTON, point, &effect)) && (effect & DROPEFFECT_COPY));
  effect = DROPEFFECT_COPY;
  const auto status = target->Drop(data, 0, point, &effect);
  assert(SUCCEEDED(status));
  const auto deadline = GetTickCount64() + 5000;
  // Async Shell copy creates/extends the destination before closing its
  // exclusive write handle. Wait for EndOperation, not just file existence.
  IDataObjectAsyncCapability* asynchronous = nullptr;
  assert(SUCCEEDED(data->QueryInterface(IID_PPV_ARGS(&asynchronous))));
  auto copied = [&] {
    BOOL running = FALSE;
    assert(SUCCEEDED(asynchronous->InOperation(&running)));
    std::error_code error;
    return !running && std::filesystem::file_size(root / name, error) == expected.size() && !error;
  };
  while (!copied() && GetTickCount64() < deadline) {
    MSG message{};
    while (PeekMessageW(&message, nullptr, 0, 0, PM_REMOVE)) {
      TranslateMessage(&message); DispatchMessageW(&message);
    }
    Sleep(5);
  }
  std::ifstream file(root / name, std::ios::binary);
  const std::string actual((std::istreambuf_iterator<char>(file)), {});
  assert(file.is_open() && actual == expected);
  file.close(); target->Release(); folder->Release(); asynchronous->Release(); data->Release();
  std::filesystem::remove(root / name); std::filesystem::remove(root);
  OleUninitialize();
  std::cout << "PASS: actual Shell folder drop creates UTF-8 TXT; Unicode text/internal drop, native preview, fresh streams and indexed formats preserved\n";
}
