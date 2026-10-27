#ifndef GLOBALSEND_SHELL_FILE_H_
#define GLOBALSEND_SHELL_FILE_H_
#include <windows.h>
#include <shlobj.h>
#include <shellapi.h>
#include <string>

// cidl=0 selects the complete item in its parent, including directory items.
// The optional opener permits testing the exact shell selection without
// opening unrelated Explorer windows for every path case.
using GlobalSendRevealOpener = decltype(&SHOpenFolderAndSelectItems);
HRESULT RevealGlobalSendFile(const std::wstring& path,
    GlobalSendRevealOpener opener = SHOpenFolderAndSelectItems);
using GlobalSendUrlOpener = decltype(&ShellExecuteW);
HRESULT OpenGlobalSendWebUrl(HWND owner, const std::string& url,
    GlobalSendUrlOpener opener = ShellExecuteW);
#endif
