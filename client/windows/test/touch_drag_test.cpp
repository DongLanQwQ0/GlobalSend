#include "../runner/touch_drag.h"
#include <roapi.h>
#include <dragdropinterop.h>
#include <winrt/Windows.ApplicationModel.DataTransfer.DragDrop.Core.h>
#include <cassert>
#include <iostream>

bool pointer_data_available = false;
int pointer_queries = 0;
UINT32 test_flags = POINTER_FLAG_DOWN | POINTER_FLAG_INCONTACT | POINTER_FLAG_PRIMARY;
BOOL WINAPI ReadPointerInMessage(UINT32 id, POINTER_INFO* info) {
  ++pointer_queries;
  if (!pointer_data_available) { SetLastError(ERROR_NO_DATA); return FALSE; }
  *info = {};
  info->pointerId = id;
  info->pointerType = PT_TOUCH;
  info->pointerFlags = test_flags;
  return TRUE;
}

void Pointer(HWND window, UINT message, UINT32 id,
    UINT32 flags = POINTER_FLAG_INCONTACT | POINTER_FLAG_PRIMARY) {
  pointer_data_available = true;
  test_flags = flags;
  SendMessageW(window, message, MAKEWPARAM(id, 0), 0);
  pointer_data_available = false;
}

void PumpUntil(const bool& completed) {
  const auto deadline = GetTickCount64() + 10000;
  while (!completed && GetTickCount64() < deadline) {
    MSG message{};
    while (PeekMessageW(&message, nullptr, 0, 0, PM_REMOVE)) {
      TranslateMessage(&message);
      DispatchMessageW(&message);
    }
    if (!completed) MsgWaitForMultipleObjectsEx(0, nullptr, 20, QS_ALLINPUT, MWMO_INPUTAVAILABLE);
  }
  assert(completed);
}

// Runs only against its own hidden HWND. No pointer injection, cursor moves,
// user clipboard reads, or interaction with another application.
int main() {
  winrt::init_apartment(winrt::apartment_type::single_threaded);
  {
  using namespace winrt::Windows::ApplicationModel::DataTransfer;
  using namespace winrt::Windows::ApplicationModel::DataTransfer::DragDrop::Core;
  HWND window = CreateWindowExW(0, L"STATIC", L"GlobalSend pointer API test", 0,
      0, 0, 320, 240, nullptr, nullptr, GetModuleHandleW(nullptr), nullptr);
  assert(window);
  std::cerr << "created hidden HWND\n";
  RegisterGlobalSendTouchDrag(window, window, ReadPointerInMessage);
  std::cerr << "registered pointer observer\n";
  assert(!HasGlobalSendTouchContact());
  pointer_data_available = true;
  SendMessageW(window, WM_POINTERDOWN, MAKEWPARAM(9, 0), 0);
  pointer_data_available = false;
  const auto queries_at_down = pointer_queries;
  assert(HasGlobalSendTouchContact());
  assert(HasGlobalSendTouchContact());
  assert(pointer_queries == queries_at_down); // No expired query from Dart's long press.
  SendMessageW(window, WM_POINTERCAPTURECHANGED, MAKEWPARAM(9, 0), reinterpret_cast<LPARAM>(window));
  assert(HasGlobalSendTouchContact());
  pointer_data_available = true;
  test_flags = POINTER_FLAG_UPDATE | POINTER_FLAG_CANCELED;
  SendMessageW(window, WM_POINTERUPDATE, MAKEWPARAM(9, 0), 0);
  pointer_data_available = false;
  assert(!HasGlobalSendTouchContact());
  pointer_data_available = true;
  test_flags = POINTER_FLAG_DOWN | POINTER_FLAG_INCONTACT | POINTER_FLAG_PRIMARY;
  SendMessageW(window, WM_POINTERDOWN, MAKEWPARAM(10, 0), 0);
  pointer_data_available = false;
  assert(HasGlobalSendTouchContact());
  SendMessageW(window, WM_POINTERUP, MAKEWPARAM(10, 0), 0);
  assert(!HasGlobalSendTouchContact());
  bool completed = false;
  StartGlobalSendTouchDrag(L"中文文本", {}, [&](bool copied, const std::string& error) {
    completed = true; assert(!copied); assert(!error.empty());
  });
  assert(completed);
  std::cerr << "no-contact callback returned\n";
  auto interop = winrt::get_activation_factory<CoreDragDropManager, IDragDropManagerInterop>();
  std::cerr << "activated drag manager factory\n";
  CoreDragDropManager manager{nullptr};
  winrt::check_hresult(interop->GetForWindow(window, winrt::guid_of<CoreDragDropManager>(), winrt::put_abi(manager)));
  std::cerr << "obtained HWND drag manager\n";
  assert(manager);
  CoreDragOperation operation;
  std::cerr << "activated CoreDragOperation\n";
  operation.AllowedOperations(DataPackageOperation::Copy);
  operation.Data().SetText(L"保留中文和换行\n第二行");
  assert(operation.AllowedOperations() == DataPackageOperation::Copy);
  assert(operation.Data().GetView().Contains(StandardDataFormats::Text()));
  std::cerr << "COPY text data set\n";
  UnregisterGlobalSendTouchDrag();
  assert(!HasGlobalSendTouchContact());

  HWND view = CreateWindowExW(0, L"STATIC", L"hidden Flutter-view stand-in", WS_CHILD,
      0, 0, 320, 240, window, nullptr, GetModuleHandleW(nullptr), nullptr);
  assert(view);
  RegisterGlobalSendTouchDrag(view, window, ReadPointerInMessage);
  Pointer(view, WM_POINTERDOWN, 20);
  SendMessageW(view, WM_POINTERCAPTURECHANGED, MAKEWPARAM(20, 0), reinterpret_cast<LPARAM>(window));
  assert(HasGlobalSendTouchContact());
  Pointer(window, WM_POINTERUP, 20, 0);
  assert(!HasGlobalSendTouchContact());
  Pointer(view, WM_POINTERUPDATE, 20);
  assert(!HasGlobalSendTouchContact()); // A queued update cannot resurrect a finished contact.
  Pointer(view, WM_POINTERDOWN, 21);
  SendMessageW(view, WM_POINTERLEAVE, MAKEWPARAM(21, 0), 0);
  assert(!HasGlobalSendTouchContact());
  std::cerr << "view-to-owner UP, stale update and leave cleanup passed\n";

#ifdef GLOBALSEND_TOUCH_DRAG_TESTING
  wchar_t fixture[MAX_PATH]{};
  assert(GetFullPathNameW(L"artifacts\\tmp\\receipt-popup\\拖出回归.txt", MAX_PATH, fixture, nullptr));
  const auto file = CreateFileW(fixture, GENERIC_WRITE, 0, nullptr, CREATE_ALWAYS,
      FILE_ATTRIBUTE_NORMAL, nullptr);
  assert(file != INVALID_HANDLE_VALUE);
  DWORD written = 0;
  assert(WriteFile(file, "export fixture", 14, &written, nullptr));
  CloseHandle(file);
  const std::wstring fixture_path(fixture);
  const auto fixture_folder = fixture_path.substr(0, fixture_path.find_last_of(L"\\/"));
  // These cases load an actual StorageFile and StorageFolder, then terminate
  // the synthetic contact before any real pointer operation can be started.
  for (int scenario = 0; scenario < 4; ++scenario) {
    Pointer(view, WM_POINTERDOWN, 30);
    bool prepared = false;
    bool finished = false;
    int callbacks = 0;
    SetGlobalSendTouchPreparedForTest([&](size_t count) {
      prepared = true;
      assert(count == 2);
      bool duplicate_returned = false;
      StartGlobalSendTouchDrag(L"duplicate", {}, [&](bool copied, const std::string& error) {
        duplicate_returned = true;
        assert(!copied);
        assert(error == "已有拖拽正在进行");
      });
      assert(duplicate_returned);
      if (scenario == 0) {
        Pointer(view, WM_POINTERUP, 30, 0);
      } else if (scenario == 1) {
        SendMessageW(view, WM_POINTERCAPTURECHANGED, MAKEWPARAM(30, 0), 0);
      } else if (scenario == 2) {
        Pointer(view, WM_POINTERUP, 30, 0);
        Pointer(view, WM_POINTERDOWN, 30); // Windows may recycle the same ID.
      } else {
        UnregisterGlobalSendTouchDrag();
        finished = true; // Engine teardown deliberately discards its callback.
      }
    });
    StartGlobalSendTouchDrag(L"", {fixture_path, fixture_folder},
        [&](bool copied, const std::string& error) {
          ++callbacks;
          assert(!copied);
          assert(error == "触点已抬起或取消，请保持长按并拖动");
          finished = true;
        });
    PumpUntil(finished);
    assert(prepared);
    assert(callbacks == (scenario == 3 ? 0 : 1));
    if (scenario == 2) assert(HasGlobalSendTouchContact());
    else assert(!HasGlobalSendTouchContact());
    SetGlobalSendTouchPreparedForTest({});
    UnregisterGlobalSendTouchDrag();
    RegisterGlobalSendTouchDrag(view, window, ReadPointerInMessage);
  }
  DeleteFileW(fixture);
  Pointer(view, WM_POINTERDOWN, 39);
  bool failure_returned = false;
  StartGlobalSendTouchDrag(L"", {fixture_path}, [&](bool copied, const std::string& error) {
    failure_returned = true;
    assert(!copied);
    assert(!error.empty());
  });
  PumpUntil(failure_returned);
  assert(!HasGlobalSendTouchContact());
  std::cerr << "real file/folder preparation: lift, capture loss, recycled ID, teardown passed\n";
#endif
  HWND dock_owner = CreateWindowExW(0, L"STATIC", L"Hidden dock pointer fixture", 0,
      0, 0, 320, 240, nullptr, nullptr, GetModuleHandleW(nullptr), nullptr);
  HWND dock_view = CreateWindowExW(0, L"STATIC", L"Hidden dock view", WS_CHILD,
      0, 0, 320, 240, dock_owner, nullptr, GetModuleHandleW(nullptr), nullptr);
  assert(dock_owner && dock_view);
  AttachGlobalSendTouchDragWindow(dock_view, dock_owner);
  Pointer(dock_view, WM_POINTERDOWN, 50);
  assert(HasGlobalSendTouchContact());
  DetachGlobalSendTouchDragWindow(dock_owner);
  assert(!HasGlobalSendTouchContact());
  Pointer(view, WM_POINTERDOWN, 51);
  assert(HasGlobalSendTouchContact());
  AttachGlobalSendTouchDragWindow(dock_view, dock_owner);
  DestroyWindow(dock_view);
  assert(HasGlobalSendTouchContact());
  Pointer(view, WM_POINTERUP, 51, 0);
  assert(!HasGlobalSendTouchContact());
  DestroyWindow(dock_owner);
  std::cerr << "main/dock pointer observer lifetime isolation passed\n";
  Pointer(view, WM_POINTERDOWN, 40);
  DestroyWindow(view);
  assert(!HasGlobalSendTouchContact());
  // Registration also removes the previous window's subclass.
  RegisterGlobalSendTouchDrag(window, window, ReadPointerInMessage);
  UnregisterGlobalSendTouchDrag();
  DestroyWindow(window);
  }
  winrt::uninit_apartment();
  std::cout << "PASS: message-scoped contact cache, owner/view lifecycle, async file/folder cancellation and recycled-pointer isolation, desktop manager and COPY data\n";
}
