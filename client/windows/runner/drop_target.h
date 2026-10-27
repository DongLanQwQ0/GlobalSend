#ifndef GLOBALSEND_DROP_TARGET_H_
#define GLOBALSEND_DROP_TARGET_H_

#include <windows.h>
#include <oleidl.h>
#include <functional>
#include <string>
#include <vector>

struct GlobalSendDroppedContent {
  std::vector<std::wstring> paths;
  std::wstring text;
  std::string error;
};

struct GlobalSendDropCallbacks {
  std::function<void(bool)> hover;
  std::function<void(GlobalSendDroppedContent)> drop;
  std::function<bool()> outgoing_drag;
  std::function<bool(POINTL)> local_drop_at;
};

// Reads OLE-owned media into application-owned strings before releasing it.
// File lists take precedence over text representations of the same payload.
bool ReadGlobalSendDrop(IDataObject* data, GlobalSendDroppedContent* content);
IDropTarget* CreateGlobalSendDropTarget(GlobalSendDropCallbacks callbacks, HWND window = nullptr);

#endif
