#ifndef GLOBALSEND_SYSTEM_INTEGRATION_H_
#define GLOBALSEND_SYSTEM_INTEGRATION_H_
#include <windows.h>
#include <flutter/binary_messenger.h>
void RegisterGlobalSendSystem(flutter::BinaryMessenger* messenger, HWND window, HWND flutter_view);
void UnregisterGlobalSendSystem();
bool HandleGlobalSendMessage(UINT message);
bool HandleGlobalSendWindowMessage(UINT message, WPARAM wparam, LPARAM lparam,
                                  LRESULT* result);
void ShowGlobalSendWindowOnFirstFrame();
#endif
