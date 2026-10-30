#ifndef GLOBALSEND_TOUCH_DRAG_H_
#define GLOBALSEND_TOUCH_DRAG_H_
#include <windows.h>
#include <functional>
#include <string>
#include <vector>

// The native pointer ID is tracked before Flutter maps it to a Dart device ID.
// Mouse uses OLE directly; touch/pen use Windows' native contact promotion.
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
// Desktop production route: Windows promotes the real held touch/pen contact
// for OLE. No SendInput fallback. Bitmap is borrowed by the synchronous runner.
void StartGlobalSendDesktopTouchDrag(std::wstring text,
    std::vector<std::wstring> paths, HWND source_owner,
    std::function<HRESULT(HBITMAP, DWORD*)> run_drag,
    std::function<void(bool, const std::string&)> completed,
    std::function<HBITMAP()> prepare_preview = {});
bool GlobalSendDesktopTouchDragCancelled();
// Native promotion uses Windows' mouse move/up state. The legacy mock fixture
// retains its held-contact test; physical mouse drags are unchanged.
HRESULT GlobalSendDesktopTouchDragStatus(BOOL escape, DWORD mouse_keys = MK_LBUTTON);
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
void SetGlobalSendPointerConversionForTest(std::function<BOOL()> converter);
#endif
#endif
