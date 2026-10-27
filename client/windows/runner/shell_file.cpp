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

HRESULT OpenGlobalSendWebUrl(HWND owner, const std::string& url,
    GlobalSendUrlOpener opener) {
  if ((url.rfind("https://", 0) != 0 && url.rfind("http://", 0) != 0) ||
      url.find('\0') != std::string::npos) return E_INVALIDARG;
  const int size = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS,
      url.data(), static_cast<int>(url.size()), nullptr, 0);
  if (!size) return E_INVALIDARG;
  std::wstring wide(size, L'\0');
  MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS,
      url.data(), static_cast<int>(url.size()), wide.data(), size);
  const auto status = reinterpret_cast<INT_PTR>(
      opener(owner, L"open", wide.c_str(), nullptr, nullptr, SW_SHOWNORMAL));
  return status > 32 ? S_OK : HRESULT_FROM_WIN32(ERROR_OPEN_FAILED);
}
