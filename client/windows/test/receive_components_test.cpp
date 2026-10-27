#include "../runner/receive_dock.h"
#include "../runner/window_lifecycle.h"
#include "../runner/single_instance.h"
#include "../runner/drag_preview.h"
#include <cassert>
#include <iostream>
#include <memory>

std::unique_ptr<GlobalSendWindowLifecycle> lifecycle;
class RecordingDockReply final : public flutter::MethodResult<flutter::EncodableValue> {
 public:
  explicit RecordingDockReply(std::vector<std::string>& events) : events_(events) {}
 protected:
  void SuccessInternal(const flutter::EncodableValue*) override { events_.push_back("success"); }
  void ErrorInternal(const std::string& code, const std::string&, const flutter::EncodableValue*) override { events_.push_back(code); }
  void NotImplementedInternal() override { events_.push_back("unimplemented"); }
 private:
  std::vector<std::string>& events_;
};
LRESULT CALLBACK Fixture(HWND window, UINT message, WPARAM wp, LPARAM lp) {
  LRESULT result{};
  if (lifecycle && lifecycle->Handle(message, wp, lp, &result)) return result;
  return DefWindowProcW(window, message, wp, lp);
}

int main() {
  for (int mode = 0; mode < 3; ++mode) {
    std::vector<std::string> events;
    auto started = std::make_unique<GlobalSendDockDragReply>(
        std::make_unique<RecordingDockReply>(events), [&] { events.push_back("finished"); });
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> asynchronous = std::move(started);
    assert(events.empty()); // Native start has returned, but export is still live.
    if (mode == 0) asynchronous->Success(flutter::EncodableValue(true));
    else if (mode == 1) asynchronous->Error("error", "fixture", flutter::EncodableValue("detail"));
    else asynchronous->NotImplemented();
    assert(events.size() == 2 && events[1] == "finished");
    assert(events[0] == (mode == 0 ? "success" : mode == 1 ? "error" : "unimplemented"));
  }
  const RECT work{-1920, 40, 0, 1080};
  const auto single = GlobalSendReceiveDockBounds(work, 96, false);
  const auto batch = GlobalSendReceiveDockBounds(work, 144, true);
  assert(single.right == -16 && single.bottom == 1064);
  assert(single.right - single.left == 480 && single.bottom - single.top == 184);
  assert(batch.right == -24 && batch.bottom == 1056);
  assert(batch.right - batch.left == 720 && batch.bottom - batch.top == 276);
  const auto clamped = GlobalSendReceiveDockBounds(RECT{0, 0, 320, 240}, 96, true);
  assert(clamped.left == 16 && clamped.top == 40 && clamped.right == 304 && clamped.bottom == 224);

  WNDCLASSW cls{};
  cls.lpfnWndProc = Fixture;
  cls.hInstance = GetModuleHandleW(nullptr);
  cls.lpszClassName = L"GlobalSendHiddenReceivePolicyFixture";
  RegisterClassW(&cls);
  HWND window = CreateWindowW(cls.lpszClassName, L"Hidden receive policy",
      WS_OVERLAPPEDWINDOW, 70, 90, 950, 650, nullptr, nullptr, cls.hInstance, nullptr);
  assert(window && !IsWindowVisible(window));
  lifecycle = std::make_unique<GlobalSendWindowLifecycle>(window,
      [](bool) {}, [](const auto&) {});
  RECT before{}, after{};
  GetWindowRect(window, &before);
  assert(!lifecycle->ShowReceived());
  assert(lifecycle->ReceiptArrivalGeneration() == 1);
  assert(!IsWindowVisible(window));
  SendMessageW(window, WM_CLOSE, 0, 0);
  assert(!lifecycle->ShowReceived());
  assert(lifecycle->ReceiptArrivalGeneration() == 2);
  lifecycle->DismissReceived(1);
  GetWindowRect(window, &after);
  assert(EqualRect(&before, &after));
  assert(!IsWindowVisible(window));

  std::vector<std::vector<std::wstring>> batches;
  SetGlobalSendLaunchConsumer([&](auto paths) { batches.push_back(std::move(paths)); });
  QueueGlobalSendLaunchPaths({L"F:\\中文 路径\\图片.png", L"F:\\文件夹"});
  assert(batches.empty());
  DrainGlobalSendLaunchFiles();
  assert(batches.size() == 1 && batches[0].size() == 2);
  std::wstring packed = L"F:\\第二张图.png";
  packed.push_back(L'\0'); packed.append(L"F:\\另一个 文件夹");
  packed.push_back(L'\0'); packed.push_back(L'\0');
  COPYDATASTRUCT data{0x47534631, static_cast<DWORD>(packed.size() * sizeof(wchar_t)), packed.data()};
  assert(SendMessageW(window, WM_COPYDATA, 0, reinterpret_cast<LPARAM>(&data)) == 1);
  assert(batches.size() == 2 && batches[1].size() == 2);
  assert(batches[1][1] == L"F:\\另一个 文件夹");
  data.cbData -= sizeof(wchar_t);
  assert(SendMessageW(window, WM_COPYDATA, 0, reinterpret_cast<LPARAM>(&data)) == 0);
  assert(batches.size() == 2);
  SetGlobalSendLaunchConsumer({});
  lifecycle.reset();
  DestroyWindow(window);
  UnregisterClassW(cls.lpszClassName, cls.hInstance);

  HBITMAP image = GlobalSendTextDragBitmap(L"这是可复制的文字预览\n第二行");
  assert(image);
  DIBSECTION shape{};
  assert(GetObjectW(image, sizeof(shape), &shape) == sizeof(shape));
  assert(shape.dsBm.bmWidth == 216 && shape.dsBm.bmHeight == 132 && shape.dsBm.bmBits);
  assert(*static_cast<const uint32_t*>(shape.dsBm.bmBits) == 0);
  DeleteObject(image);
  std::cout << "PASS lower-right DPI bounds, hidden-main geometry/focus invariant, startup/WM_COPYDATA Unicode multi-path queue, native text drag bitmap\n";
}
