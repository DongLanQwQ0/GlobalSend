#include "../runner/remote_drag_data.h"
#include <shlobj.h>
#include <shobjidl.h>
#include <cassert>
#include <future>
#include <iostream>

int main() {
  assert(SUCCEEDED(CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED)));
  assert(!GlobalSendRemoteDragBusy());
  wchar_t temporary[MAX_PATH]{}; GetTempPathW(MAX_PATH, temporary);
  const std::wstring root = std::wstring(temporary) + L"GlobalSend-remote-test-" + std::to_wstring(GetCurrentProcessId());
  CreateDirectoryW(root.c_str(), nullptr); CreateDirectoryW((root + L"\\empty").c_str(), nullptr);
  const auto file = root + L"\\note.txt";
  HANDLE output = CreateFileW(file.c_str(), GENERIC_WRITE, 0, nullptr, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
  DWORD count = 0; assert(WriteFile(output, "remote content", 14, &count, nullptr)); CloseHandle(output);
  int requests = 0;
  const auto creator_thread = GetCurrentThreadId();
  GlobalSendRemoteResolved complete;
  HANDLE requested = CreateEventW(nullptr, TRUE, FALSE, nullptr);
  IDataObject* data = nullptr;
  const std::vector<GlobalSendRemoteFile> manifest{{L"Folder", 0, true}, {L"Folder/empty", 0, true}, {L"Folder/note.txt", 14, false}};
  assert(SUCCEEDED(CreateGlobalSendRemoteDragData(manifest, [&](GlobalSendRemoteResolved resolve) {
    assert(GetCurrentThreadId() != creator_thread);
    ++requests; complete = std::move(resolve); SetEvent(requested);
  }, &data)));
  FORMATETC descriptor{static_cast<CLIPFORMAT>(RegisterClipboardFormatW(CFSTR_FILEDESCRIPTORW)), nullptr, DVASPECT_CONTENT, -1, TYMED_HGLOBAL};
  STGMEDIUM medium{}; assert(SUCCEEDED(data->GetData(&descriptor, &medium)));
  const auto* tree = static_cast<FILEGROUPDESCRIPTORW*>(GlobalLock(medium.hGlobal));
  assert(tree->cItems == 3); assert(tree->fgd[1].dwFileAttributes == FILE_ATTRIBUTE_DIRECTORY);
  assert(std::wstring(tree->fgd[2].cFileName) == L"Folder\\note.txt");
  GlobalUnlock(medium.hGlobal); ReleaseStgMedium(&medium); assert(requests == 0);
  FORMATETC contents{static_cast<CLIPFORMAT>(RegisterClipboardFormatW(CFSTR_FILECONTENTS)), nullptr, DVASPECT_CONTENT, 2, TYMED_ISTREAM};
  assert(SUCCEEDED(data->GetData(&contents, &medium)));
  IStream* stream = medium.pstm; stream->AddRef(); ReleaseStgMedium(&medium);
  STATSTG stat{}; assert(SUCCEEDED(stream->Stat(&stat, STATFLAG_NONAME)) && stat.cbSize.QuadPart == 14); assert(requests == 0);
  assert(GlobalSendRemoteDragBusy());
  char unused = 0; ULONG zero = 1; assert(stream->Read(&unused, 0, &zero) == S_OK && zero == 0 && requests == 0);
  IDataObjectAsyncCapability* async = nullptr; assert(SUCCEEDED(data->QueryInterface(IID_PPV_ARGS(&async))));
  assert(SUCCEEDED(async->StartOperation(nullptr))); data->Release();
  IStream* marshaled = nullptr;
  assert(SUCCEEDED(CoMarshalInterThreadInterfaceInStream(IID_IStream, stream, &marshaled))); stream->Release();
  auto reading = std::async(std::launch::async, [marshaled] {
    CoInitializeEx(nullptr, COINIT_MULTITHREADED);
    IStream* stream = nullptr; assert(SUCCEEDED(CoGetInterfaceAndReleaseStream(marshaled, IID_PPV_ARGS(&stream))));
    char bytes[20]{}; ULONG read = 0; const auto result = stream->Read(bytes, 20, &read);
    assert(result == S_FALSE && read == 14 && std::string(bytes, read) == "remote content");
    LARGE_INTEGER position{}; position.QuadPart = 7; assert(SUCCEEDED(stream->Seek(position, STREAM_SEEK_SET, nullptr)));
    assert(stream->Read(bytes, 7, &read) == S_OK && std::string(bytes, read) == "content");
    stream->Release(); CoUninitialize();
  });
  assert(WaitForSingleObject(requested, 2000) == WAIT_OBJECT_0);
  // The creator/UI thread is free to run and deliver a response while the
  // target's extraction worker waits. No descriptor query started a download.
  assert(requests == 1); complete({root}, ""); reading.get();
  // DoDragDrop/source ownership has ended, but the asynchronous extraction
  // still holds the update gate until its explicit EndOperation.
  assert(GlobalSendRemoteDragBusy());
  assert(SUCCEEDED(async->EndOperation(S_OK, nullptr, DROPEFFECT_COPY))); async->Release();
  assert(!GlobalSendRemoteDragBusy());
  assert(SUCCEEDED(CreateGlobalSendRemoteDragData({{L"file.txt", 4, false}}, [&](GlobalSendRemoteResolved value) {++requests;value({}, "source offline");}, &data)));
  contents.lindex = 0; assert(SUCCEEDED(data->GetData(&contents, &medium)));
  char bytes[4]; ULONG read = 9; assert(medium.pstm->Read(bytes, 4, &read) == STG_E_READFAULT && read == 0); ReleaseStgMedium(&medium); data->Release();
  assert(SUCCEEDED(CreateGlobalSendRemoteDragData({{L"cancel.txt", 4, false}}, [&](GlobalSendRemoteResolved) {assert(false);}, &data))); data->Release();
  assert(FAILED(CreateGlobalSendRemoteDragData({{L"../escape.txt", 4, false}}, [](GlobalSendRemoteResolved) {}, &data)));
  CloseHandle(requested); DeleteFileW(file.c_str()); RemoveDirectoryW((root + L"\\empty").c_str()); RemoveDirectoryW(root.c_str());
  CoUninitialize(); std::cout << "PASS metadata-only enumeration, lazy worker read, one resolution, async lifetime, tree/empty directory, seek, source error and cancelled-unused source\n";
}
