#ifndef GLOBALSEND_TOUCH_DRAG_H_
#define GLOBALSEND_TOUCH_DRAG_H_
#include <windows.h>
#include <functional>
#include <string>
#include <vector>

// The native pointer ID is tracked before Flutter maps it to a Dart device ID.
// Mouse uses OLE directly; touch/pen use the held-contact desktop adapter.
using GlobalSendPointerInfoReader = BOOL (WINAPI*)(UINT32, POINTER_INFO*);
void RegisterGlobalSendTouchDrag(HWND view, HWND owner,
    GlobalSendPointerInfoReader reader = GetPointerInfo);
void UnregisterGlobalSendTouchDrag();
// A receive-dock view participates without replacing the primary view observer.
void AttachGlobalSendTouchDragWindow(HWND view, HWND owner);
void DetachGlobalSendTouchDragWindow(HWND owner);
bool HasGlobalSendTouchContact();
bool GlobalSendHeldTouchPoint(HWND owner, POINT* screen_point);
// Retained diagnostic WinRT route (not called by production UI). Stage errors
// distinguish capabilities/configuration from actual StartAsync failure.
void StartGlobalSendTouchDrag(std::wstring text, std::vector<std::wstring> paths,
    std::function<void(bool, const std::string&)> completed);
// Desktop production route: real held touch/pen drives an OLE drag, including
// its mouse-state adapter. Bitmap is borrowed only for the synchronous runner.
void StartGlobalSendDesktopTouchDrag(std::wstring text,
    std::vector<std::wstring> paths, HWND source_owner,
    std::function<HRESULT(HBITMAP, DWORD*)> run_drag,
    std::function<void(bool, const std::string&)> completed,
    std::function<HBITMAP()> prepare_preview = {});
bool GlobalSendDesktopTouchDragCancelled();
// OLE mouse key bits can lag behind promoted right-click input. The real held
// contact decides touch continuation/drop; mouse drags retain their own keys.
HRESULT GlobalSendDesktopTouchDragStatus(BOOL escape);
INPUT GlobalSendTouchMouseInput(POINT screen_point, DWORD flags, RECT desktop);
#ifdef GLOBALSEND_TOUCH_DRAG_TESTING
// A deterministic cancellation boundary after real asynchronous file loading.
// Tests end the contact here so they never start a shell drag with fake input.
void SetGlobalSendTouchPreparedForTest(std::function<void(size_t)> prepared);
void SetGlobalSendDesktopTouchTestHooks(
    std::function<bool(const INPUT&)> sender,
    std::function<bool(HWND)> input_available);
void GlobalSendDesktopForeignMouseForTest(UINT message, ULONG_PTR marker = 0);
bool GlobalSendTouchMouseButtonsAvailableForTest(HWND owner, DWORD pressed);
#endif
#endif
