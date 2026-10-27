#include <windows.h>
#include <roapi.h>
#include <dragdropinterop.h>
#include <shobjidl_core.h>
#include <winrt/Windows.ApplicationModel.DataTransfer.h>
#include <winrt/Windows.ApplicationModel.DataTransfer.DragDrop.Core.h>
#include <winrt/Windows.Graphics.Imaging.h>
#include <winrt/Windows.Foundation.h>
#include <iostream>
#include <functional>

// Capability queries only. Never StartAsync: no synthetic contact, system drag,
// visible window, clipboard mutation, or interaction with another app.
int main(int argc, char** argv) {
  const bool negative_start = argc == 2 && std::string(argv[1]) == "--start-invalid-pointer";
  if (negative_start) {
    GUITHREADINFO input{sizeof(GUITHREADINFO)};
    const bool queried = !!GetGUIThreadInfo(0, &input);
    const auto query_error = queried ? ERROR_SUCCESS : GetLastError();
    const bool left = !!(GetAsyncKeyState(VK_LBUTTON) & 0x8000);
    const bool right = !!(GetAsyncKeyState(VK_RBUTTON) & 0x8000);
    const bool middle = !!(GetAsyncKeyState(VK_MBUTTON) & 0x8000);
    if (!queried || input.hwndCapture || left || right || middle) {
      std::cout << "SKIP: another input/capture may be active; GUI query=" << queried
                << ", error=" << query_error << ", capture=" << input.hwndCapture
                << ", buttons=" << left << right << middle << "\n";
      return 2;
    }
  }
  winrt::init_apartment(winrt::apartment_type::single_threaded);
  using namespace winrt::Windows::ApplicationModel::DataTransfer;
  using namespace winrt::Windows::ApplicationModel::DataTransfer::DragDrop::Core;
  using namespace winrt::Windows::Graphics::Imaging;
  auto step = [](const char* name, std::function<void()> action) {
    try { action(); std::cout << name << ": S_OK\n"; }
    catch (const winrt::hresult_error& error) {
      std::cout << name << ": 0x" << std::hex << static_cast<unsigned long>(error.code().value)
                << std::dec << " " << winrt::to_string(error.message()) << "\n";
    }
  };
  HWND window = CreateWindowExW(0, L"STATIC", L"Hidden drag capability probe", 0,
      0, 0, 320, 240, nullptr, nullptr, GetModuleHandleW(nullptr), nullptr);
  {
    CoreDragOperation drag{nullptr};
    step("CoreDragOperation activation", [&] { drag = CoreDragOperation(); });
    if (drag) {
      step("QI ICoreDragOperation", [&] { drag.as<ICoreDragOperation>(); });
      step("QI ICoreDragOperation2", [&] { drag.as<ICoreDragOperation2>(); });
      step("QI IInitializeWithWindow + Initialize(HWND)", [&] {
        winrt::check_hresult(drag.as<IInitializeWithWindow>()->Initialize(window));
      });
      step("SetPointerId(0) [configuration only]", [&] { drag.SetPointerId(0); });
      step("AllowedOperations(Copy)", [&] { drag.AllowedOperations(DataPackageOperation::Copy); });
      step("Data.RequestedOperation", [&] { drag.Data().RequestedOperation(DataPackageOperation::Copy); });
      step("Data.SetText", [&] { drag.Data().SetText(L"probe"); });
      step("SetDragUIContentFromSoftwareBitmap", [&] {
        SoftwareBitmap image(BitmapPixelFormat::Bgra8, 16, 16, BitmapAlphaMode::Premultiplied);
        drag.SetDragUIContentFromSoftwareBitmap(image, winrt::Windows::Foundation::Point{0, 0});
      });
    }
    step("CoreDragDropManager GetForWindow", [&] {
      auto factory = winrt::get_activation_factory<CoreDragDropManager, IDragDropManagerInterop>();
      CoreDragDropManager manager{nullptr};
      winrt::check_hresult(factory->GetForWindow(window, winrt::guid_of<CoreDragDropManager>(), winrt::put_abi(manager)));
    });
    if (negative_start && drag) {
      // Zero is never a Windows touch pointer ID. This one-off diagnostic is
      // explicitly opted in; do not turn it into a fake-input success test.
      step("CoreDragOperation.StartAsync(pointerId=0)", [&] {
        auto pending = drag.StartAsync();
        std::cout << "StartAsync returned; status=" << static_cast<int>(pending.Status()) << "\n";
        if (pending.Status() == winrt::Windows::Foundation::AsyncStatus::Started) {
          pending.Cancel(); // Only the operation returned by this probe.
          std::cout << "Cancelled own pending operation\n";
          const auto deadline = GetTickCount64() + 1000;
          while (pending.Status() == winrt::Windows::Foundation::AsyncStatus::Started && GetTickCount64() < deadline) {
            MSG message{};
            while (PeekMessageW(&message, nullptr, 0, 0, PM_REMOVE)) DispatchMessageW(&message);
            Sleep(10);
          }
        }
        std::cout << "Final own-operation status=" << static_cast<int>(pending.Status()) << "\n";
        if (pending.Status() == winrt::Windows::Foundation::AsyncStatus::Error) {
          winrt::check_hresult(pending.ErrorCode());
        }
      });
    }
  }
  DestroyWindow(window);
  winrt::uninit_apartment();
}
