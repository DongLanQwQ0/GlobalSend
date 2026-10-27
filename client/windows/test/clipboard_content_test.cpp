#include "../runner/clipboard_content.h"
#include <ole2.h>
#include <shellapi.h>
#include <shlobj.h>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <vector>
#include <cstring>

namespace {
void Check(bool value, const char* message) { if (!value) throw message; }
void SetBytes(HWND window, UINT format, const void* data, size_t length) {
  Check(OpenClipboard(window) != FALSE, "open synthetic clipboard");
  const bool emptied = EmptyClipboard() != FALSE;
  HGLOBAL memory = GlobalAlloc(GMEM_MOVEABLE, length);
  void* value = memory ? GlobalLock(memory) : nullptr;
  if (!emptied || !value) { CloseClipboard(); throw "prepare synthetic clipboard"; }
  memcpy(value, data, length); GlobalUnlock(memory);
  const bool set = SetClipboardData(format, memory) != nullptr;
  CloseClipboard();
  if (!set) GlobalFree(memory);
  Check(set, "publish synthetic clipboard");
}
std::vector<uint8_t> ReadBytes(const std::filesystem::path& path) {
  std::ifstream input(path, std::ios::binary);
  return {std::istreambuf_iterator<char>(input), std::istreambuf_iterator<char>()};
}
void CheckBmp(const GlobalSendClipboardContent& content) {
  Check(content.error.empty() && content.paths.size() == 1 && content.temporary_paths == content.paths, "bitmap ownership");
  const auto bytes = ReadBytes(content.paths[0]);
  Check(bytes.size() > sizeof(BITMAPFILEHEADER) + sizeof(BITMAPINFOHEADER), "bitmap has pixels");
  Check(bytes[0] == 'B' && bytes[1] == 'M', "bitmap signature");
}
}  // namespace

int wmain(int argc, wchar_t** argv) {
  if (argc != 4 || std::wstring(argv[3]) != L"--empty-clipboard-only") {
    std::cerr << "usage: clipboard_content_test <project output dir> <synthetic PNG> --empty-clipboard-only\n";
    return 64;
  }
  if (FAILED(OleInitialize(nullptr))) return 3;
  HWND window = CreateWindowExW(0, L"STATIC", L"GlobalSend clipboard test", 0,
      0, 0, 1, 1, nullptr, nullptr, GetModuleHandleW(nullptr), nullptr);
  // A borrowed OleGetClipboard proxy does not guarantee independent backup:
  // delayed formats can stop rendering once the old clipboard is replaced.
  // Never overwrite a nonempty user clipboard. This opt-in runtime test is
  // available only when the operator has already left it empty.
  if (!OpenClipboard(window)) { DestroyWindow(window); OleUninitialize(); return 3; }
  SetLastError(ERROR_SUCCESS);
  const bool empty = CountClipboardFormats() == 0 && GetLastError() == ERROR_SUCCESS;
  CloseClipboard();
  if (!empty) {
    std::cerr << "Clipboard tests skipped before any write: clipboard is not empty.\n";
    DestroyWindow(window); OleUninitialize(); return 3;
  }
  const std::filesystem::path output = std::filesystem::absolute(argv[1]);
  int status = 0, count = 0;
  try {
    std::filesystem::create_directories(output / L"文件夹");
    const auto bitmap_path = (output / L"clipboard.bmp").wstring();
    const std::wstring text = L"第一行\r\n第二行：完整中文与表情 🙂";
    SetBytes(window, CF_UNICODETEXT, text.c_str(), (text.size() + 1) * sizeof(wchar_t));
    Check(GlobalSendClipboardKind() == "text", "detect Unicode text");
    auto content = ReadGlobalSendClipboard(window, bitmap_path);
    Check(content.texts == std::vector<std::wstring>{text} && content.paths.empty(), "Unicode text roundtrip");
    std::cout << "PASS: Unicode multiline text\n"; ++count;

    const auto source = output / L"资料.txt";
    { std::ofstream file(source); file << "original remains external"; }
    const std::vector<std::wstring> paths = {source.wstring(), (output / L"文件夹").wstring()};
    std::wstring names;
    for (const auto& path : paths) { names += path; names.push_back(L'\0'); }
    names.push_back(L'\0');
    DROPFILES drop{}; drop.pFiles = sizeof(drop); drop.fWide = TRUE;
    std::vector<uint8_t> payload(sizeof(drop) + names.size() * sizeof(wchar_t));
    memcpy(payload.data(), &drop, sizeof(drop)); memcpy(payload.data() + sizeof(drop), names.data(), names.size() * sizeof(wchar_t));
    SetBytes(window, CF_HDROP, payload.data(), payload.size());
    Check(GlobalSendClipboardKind() == "files", "detect file list");
    content = ReadGlobalSendClipboard(window, bitmap_path);
    Check(content.paths == paths && content.texts.empty() && content.temporary_paths.empty(), "files and folder use external paths");
    std::cout << "PASS: Unicode file + folder references\n"; ++count;

    const auto png = ReadBytes(argv[2]); Check(!png.empty(), "synthetic PNG exists");
    SetBytes(window, RegisterClipboardFormatW(L"PNG"), png.data(), png.size());
    Check(GlobalSendClipboardKind() == "image", "detect PNG-only clipboard");
    content = ReadGlobalSendClipboard(window, bitmap_path);
    Check(content.paths.size() == 1 && std::filesystem::path(content.paths[0]).extension() == L".png", "PNG filename extension");
    Check(content.temporary_paths == content.paths && ReadBytes(content.paths[0]) == png, "PNG preserves bytes and ownership");
    std::cout << "PASS: PNG-only image with exact bytes\n"; ++count;

    BITMAPINFOHEADER dib{}; dib.biSize = sizeof(dib); dib.biWidth = 2; dib.biHeight = 1;
    dib.biPlanes = 1; dib.biBitCount = 24; dib.biCompression = BI_RGB; dib.biSizeImage = 8;
    std::vector<uint8_t> pixels(sizeof(dib) + 8, 0);
    memcpy(pixels.data(), &dib, sizeof(dib)); pixels[sizeof(dib) + 2] = 255; pixels[sizeof(dib) + 4] = 255;
    SetBytes(window, CF_DIB, pixels.data(), pixels.size());
    content = ReadGlobalSendClipboard(window, bitmap_path); CheckBmp(content);
    std::cout << "PASS: DIB screenshot\n"; ++count;

    BITMAPV5HEADER v5{}; v5.bV5Size = sizeof(v5); v5.bV5Width = 2; v5.bV5Height = 1;
    v5.bV5Planes = 1; v5.bV5BitCount = 32; v5.bV5Compression = BI_BITFIELDS;
    v5.bV5RedMask = 0x00ff0000; v5.bV5GreenMask = 0x0000ff00; v5.bV5BlueMask = 0x000000ff; v5.bV5AlphaMask = 0xff000000;
    v5.bV5CSType = LCS_sRGB;
    pixels.resize(sizeof(v5) + 8); memcpy(pixels.data(), &v5, sizeof(v5));
    const uint32_t rgba[] = {0xffff0000, 0xff00ff00}; memcpy(pixels.data() + sizeof(v5), rgba, sizeof(rgba));
    SetBytes(window, CF_DIBV5, pixels.data(), pixels.size());
    content = ReadGlobalSendClipboard(window, bitmap_path); CheckBmp(content);
    std::cout << "PASS: DIBV5 screenshot\n"; ++count;

    Check(OpenClipboard(window) != FALSE, "open standard bitmap clipboard");
    EmptyClipboard();
    HBITMAP bitmap = CreateBitmap(2, 1, 1, 32, rgba);
    const bool bitmap_set = SetClipboardData(CF_BITMAP, bitmap) != nullptr;
    CloseClipboard(); Check(bitmap_set, "publish standard bitmap");
    Check(GlobalSendClipboardKind() == "image", "detect standard bitmap");
    content = ReadGlobalSendClipboard(window, bitmap_path); CheckBmp(content);
    std::cout << "PASS: CF_BITMAP image (including Windows DIB synthesis)\n"; ++count;
  } catch (const char* message) { std::cerr << "FAIL: " << message << "\n"; status = 1; }
  catch (const std::exception& error) { std::cerr << "FAIL: " << error.what() << "\n"; status = 1; }
  bool restored = OpenClipboard(window) != FALSE;
  if (restored) { restored = EmptyClipboard() != FALSE; CloseClipboard(); }
  if (!restored) { std::cerr << "FAIL: original empty clipboard restoration failed\n"; status = 2; }
  else std::cout << "RESTORED: original empty clipboard\n";
  DestroyWindow(window); OleUninitialize();
  std::ofstream report(output / L"result.json");
  report << "{\"realClipboardFormatsPassed\":" << count << ",\"originalRestored\":"
      << (restored ? "true" : "false") << ",\"exitCode\":" << status << "}";
  return status;
}
