#ifndef GLOBALSEND_CLIPBOARD_IMAGE_H_
#define GLOBALSEND_CLIPBOARD_IMAGE_H_
#include <windows.h>
#include <string>
#include <vector>

struct GlobalSendClipboardImage {
  std::vector<unsigned char> png, dib, dib_v5;
  HRESULT status = E_FAIL;
};

// Decode and encode on a COM-initialized worker, not the platform thread.
GlobalSendClipboardImage PrepareGlobalSendClipboardImage(const std::wstring& path);
#endif
