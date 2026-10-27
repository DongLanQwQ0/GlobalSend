#ifndef GLOBALSEND_WINDOW_STARTUP_H_
#define GLOBALSEND_WINDOW_STARTUP_H_

#include "window_lifecycle.h"
#include <filesystem>
#include <optional>
#include <string>

// Uses the same window.json as Dart: environment, installed pointer, then
// path_provider's roaming directory derived from the executable VERSIONINFO.
std::filesystem::path GlobalSendWindowStatePath(
    const std::filesystem::path& executable, const std::wstring& data_override,
    const std::filesystem::path& roaming);
std::optional<GlobalSendWindowState> ReadGlobalSendWindowState(
    const std::filesystem::path& path);
std::optional<GlobalSendWindowState> LoadGlobalSendStartupWindow();

#endif
