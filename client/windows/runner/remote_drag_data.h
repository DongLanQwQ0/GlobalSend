#ifndef GLOBALSEND_REMOTE_DRAG_DATA_H_
#define GLOBALSEND_REMOTE_DRAG_DATA_H_
#include <windows.h>
#include <objidl.h>
#include <functional>
#include <string>
#include <vector>

struct GlobalSendRemoteFile {
  std::wstring relative_path;
  uint64_t size = 0;
  bool directory = false;
};
using GlobalSendRemoteResolved = std::function<void(std::vector<std::wstring>, std::string)>;
using GlobalSendRemoteResolver = std::function<void(GlobalSendRemoteResolved)>;

// Metadata is available immediately. Only a FILECONTENTS stream read resolves
// the original file/tree; the same resolution is shared by every child stream.
HRESULT CreateGlobalSendRemoteDragData(const std::vector<GlobalSendRemoteFile>& files,
    GlobalSendRemoteResolver resolve, IDataObject** output);
bool GlobalSendRemoteDragBusy();
// May run on a COM provider worker; the caller must marshal UI work itself.
void SetGlobalSendRemoteDragActivityChanged(std::function<void()> changed);
#endif
