#ifndef GLOBALSEND_CLIPBOARD_CONTENT_H_
#define GLOBALSEND_CLIPBOARD_CONTENT_H_
#include <windows.h>
#include <string>
#include <vector>

struct GlobalSendClipboardContent {
  std::vector<std::wstring> paths, texts, temporary_paths;
  std::string error;
};

// Format discovery does not open/read clipboard contents. Both the button and
// Ctrl+V use the same importer after the explicit user action.
std::string GlobalSendClipboardKind();
GlobalSendClipboardContent ReadGlobalSendClipboard(HWND owner,
    const std::wstring& bitmap_path);
#endif
