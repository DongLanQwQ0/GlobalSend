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
// Desktop production route: prepare off-thread, then enter OLE from a real
// native input message. Reuse an existing system-promoted mouse stream or
// promote the held pointer in its dispatch context. OLE starts only after an
// actual system mouse DOWN/MOVE. ready_preview transfers a ready RGBA bitmap
// without a worker round-trip; the synchronous OLE callback borrows it.
void StartGlobalSendDesktopTouchDrag(std::wstring text,
    std::vector<std::wstring> paths, HWND source_owner,
    std::function<HRESULT(HBITMAP, DWORD*)> run_drag,
    std::function<void(bool, const std::string&)> completed,
    std::function<HBITMAP()> prepare_preview = {},
    HBITMAP ready_preview = nullptr);
bool GlobalSendDesktopTouchDragCancelled();
// Native promotion uses Windows' mouse move/up state. Physical mouse drags
// are unchanged; no injected mouse packets or low-level hook are used.
HRESULT GlobalSendDesktopTouchDragStatus(BOOL escape, DWORD mouse_keys = MK_LBUTTON);
#ifdef GLOBALSEND_TOUCH_DRAG_TESTING
// Deterministic boundary after asynchronous preparation. Tests own hidden HWNDs
// and replace the converter/OLE callback, never injecting real input.
void SetGlobalSendTouchPreparedForTest(std::function<void(size_t)> prepared);
void SetGlobalSendDesktopTouchInputAvailableForTest(std::function<bool(HWND)> input_available);
bool GlobalSendTouchMouseButtonsAvailableForTest(HWND owner, DWORD pressed);
void SetGlobalSendPointerConversionForTest(std::function<BOOL()> converter);
#endif
#endif
