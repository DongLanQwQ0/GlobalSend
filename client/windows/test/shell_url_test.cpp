#include "../runner/shell_file.h"
#include <cassert>
#include <string>

std::wstring opened;
int calls = 0;
INT_PTR status = 33;
HINSTANCE WINAPI FakeOpen(HWND, LPCWSTR verb, LPCWSTR path, LPCWSTR args,
    LPCWSTR directory, int show) {
  ++calls;
  assert(std::wstring(verb) == L"open");
  assert(args == nullptr && directory == nullptr && show == SW_SHOWNORMAL);
  opened = path;
  return reinterpret_cast<HINSTANCE>(status);
}
int main() {
  assert(SUCCEEDED(OpenGlobalSendWebUrl(nullptr, "https://example.com/path?q=1", FakeOpen)));
  assert(opened == L"https://example.com/path?q=1");
  assert(SUCCEEDED(OpenGlobalSendWebUrl(nullptr, "https://example.com/中文", FakeOpen)));
  assert(opened == L"https://example.com/中文");
  const int before = calls;
  assert(OpenGlobalSendWebUrl(nullptr, "file:///C:/test.exe", FakeOpen) == E_INVALIDARG);
  assert(calls == before);
  status = 2;
  assert(FAILED(OpenGlobalSendWebUrl(nullptr, "http://example.com", FakeOpen)));
}
