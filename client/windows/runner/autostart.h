#ifndef GLOBALSEND_AUTOSTART_H_
#define GLOBALSEND_AUTOSTART_H_
#include <string>

std::wstring GlobalSendAutoStartCommand(const std::wstring& executable);
bool GlobalSendAutoStartEnabled();
void SetGlobalSendAutoStart(bool enabled);
#endif
