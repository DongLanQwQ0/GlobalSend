#include "shell_file.h"
#include <memory>

namespace {
struct FreePidl {
  using pointer = PIDLIST_ABSOLUTE;
  void operator()(pointer value) const { CoTaskMemFree(value); }
};
}

HRESULT RevealGlobalSendFile(const std::wstring& path,
    GlobalSendRevealOpener opener) {
  if (path.empty() || path.find(L'\0') != std::wstring::npos) return E_INVALIDARG;
  const DWORD required = GetFullPathNameW(path.c_str(), 0, nullptr, nullptr);
  if (!required) return HRESULT_FROM_WIN32(GetLastError());
  std::wstring absolute(required, L'\0');
  const DWORD length = GetFullPathNameW(path.c_str(), required, absolute.data(), nullptr);
  if (!length || length >= required) return HRESULT_FROM_WIN32(ERROR_INVALID_NAME);
  absolute.resize(length);
  if (GetFileAttributesW(absolute.c_str()) == INVALID_FILE_ATTRIBUTES)
    return HRESULT_FROM_WIN32(GetLastError());
  PIDLIST_ABSOLUTE raw = nullptr;
  const HRESULT parsed = SHParseDisplayName(absolute.c_str(), nullptr, &raw, 0, nullptr);
  std::unique_ptr<ITEMIDLIST, FreePidl> item(raw);
  if (FAILED(parsed)) return parsed;
  return opener(item.get(), 0, nullptr, 0);
}
