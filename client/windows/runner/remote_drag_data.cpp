#include "remote_drag_data.h"
#include <shlobj.h>
#include <shobjidl.h>
#include <shlwapi.h>
#include <atomic>
#include <condition_variable>
#include <cstring>
#include <memory>
#include <mutex>
#include <future>
#include <queue>
#include <thread>

namespace {
std::atomic<int> provider_leases{0};
std::mutex activity_mutex;
std::function<void()> activity_changed;
void ChangeLease(int change) {
  provider_leases.fetch_add(change);
  std::function<void()> notify;
  { std::lock_guard<std::mutex> lock(activity_mutex); notify = activity_changed; }
  if (notify) notify();
}
CLIPFORMAT DescriptorFormat() { return static_cast<CLIPFORMAT>(RegisterClipboardFormatW(CFSTR_FILEDESCRIPTORW)); }
CLIPFORMAT ContentsFormat() { return static_cast<CLIPFORMAT>(RegisterClipboardFormatW(CFSTR_FILECONTENTS)); }
bool ValidRelative(const std::wstring& name) {
  if (name.empty() || name.size() >= MAX_PATH || name.front() == L'\\' || name.front() == L'/' || name.find(L':') != std::wstring::npos) return false;
  size_t from = 0;
  while (from <= name.size()) {
    const auto to = name.find_first_of(L"\\/", from);
    const auto part = name.substr(from, to == std::wstring::npos ? to : to - from);
    if (part.empty() || part == L"." || part == L"..") return false;
    if (to == std::wstring::npos) break;
    from = to + 1;
  }
  return true;
}
struct Resolution : std::enable_shared_from_this<Resolution> {
  explicit Resolution(GlobalSendRemoteResolver value) : resolver(std::move(value)) {}
  std::mutex mutex;
  std::condition_variable changed;
  bool started = false, finished = false;
  std::vector<std::wstring> paths;
  std::string error;
  GlobalSendRemoteResolver resolver;
  HRESULT Root(std::wstring* root) {
    std::unique_lock<std::mutex> lock(mutex);
    if (!started) {
      started = true;
      const auto self = shared_from_this();
      lock.unlock();
      resolver([self](std::vector<std::wstring> paths, std::string error) {
        std::lock_guard<std::mutex> guard(self->mutex);
        if (self->finished) return;
        self->paths = std::move(paths); self->error = std::move(error); self->finished = true;
        self->changed.notify_all();
      });
      lock.lock();
    }
    changed.wait(lock, [&] { return finished; });
    if (!error.empty() || paths.size() != 1 || paths.front().empty()) return STG_E_READFAULT;
    *root = paths.front(); return S_OK;
  }
};

// Created in a dedicated MTA, not Flutter's STA. Cross-process COM reads must
// execute on provider workers even when a target uses the standard IStream proxy.
class RemoteStream final : public IStream {
 public:
  RemoteStream(std::shared_ptr<Resolution> resolution, GlobalSendRemoteFile file)
      : resolution_(std::move(resolution)), file_(std::move(file)) { ChangeLease(1); }
  HRESULT STDMETHODCALLTYPE QueryInterface(REFIID iid, void** out) override {
    if (!out) return E_POINTER;
    *out = nullptr;
    if (iid == IID_IUnknown || iid == IID_ISequentialStream || iid == IID_IStream) {
      *out = static_cast<IStream*>(this); AddRef(); return S_OK;
    }
    return E_NOINTERFACE;
  }
  ULONG STDMETHODCALLTYPE AddRef() override { return ++references_; }
  ULONG STDMETHODCALLTYPE Release() override { const auto count = --references_; if (!count) delete this; return count; }
  HRESULT STDMETHODCALLTYPE Read(void* buffer, ULONG count, ULONG* read) override {
    if (read) *read = 0;
    if (!count) return S_OK;
    if (count && !buffer) return STG_E_INVALIDPOINTER;
    std::lock_guard<std::mutex> lock(mutex_);
    const auto ready = Open(); if (FAILED(ready)) return ready;
    LARGE_INTEGER position{}; position.QuadPart = offset_;
    if (!SetFilePointerEx(handle_, position, nullptr, FILE_BEGIN)) return HRESULT_FROM_WIN32(GetLastError());
    DWORD completed = 0;
    if (!ReadFile(handle_, buffer, count, &completed, nullptr)) return HRESULT_FROM_WIN32(GetLastError());
    offset_ += completed; if (read) *read = completed;
    return completed == count ? S_OK : S_FALSE;
  }
  HRESULT STDMETHODCALLTYPE Write(const void*, ULONG, ULONG*) override { return STG_E_ACCESSDENIED; }
  HRESULT STDMETHODCALLTYPE Seek(LARGE_INTEGER move, DWORD origin, ULARGE_INTEGER* position) override {
    std::lock_guard<std::mutex> lock(mutex_);
    const int64_t base = origin == STREAM_SEEK_SET ? 0 : origin == STREAM_SEEK_CUR ? offset_ : origin == STREAM_SEEK_END ? static_cast<int64_t>(file_.size) : -1;
    if (base < 0 || move.QuadPart < -base) return STG_E_INVALIDFUNCTION;
    offset_ = base + move.QuadPart; if (position) position->QuadPart = offset_; return S_OK;
  }
  HRESULT STDMETHODCALLTYPE SetSize(ULARGE_INTEGER) override { return STG_E_ACCESSDENIED; }
  HRESULT STDMETHODCALLTYPE CopyTo(IStream* target, ULARGE_INTEGER requested, ULARGE_INTEGER* read, ULARGE_INTEGER* written) override {
    if (!target) return STG_E_INVALIDPOINTER;
    if (read) read->QuadPart = 0; if (written) written->QuadPart = 0;
    char block[65536]; uint64_t remaining = requested.QuadPart;
    while (remaining) {
      ULONG got = 0, sent = 0; const auto amount = static_cast<ULONG>(remaining > sizeof(block) ? sizeof(block) : remaining);
      const auto status = Read(block, amount, &got); if (FAILED(status)) return status;
      if (!got) return S_OK;
      if (read) read->QuadPart += got;
      const auto output = target->Write(block, got, &sent); if (written) written->QuadPart += sent;
      if (FAILED(output)) return output; if (sent != got) return STG_E_WRITEFAULT;
      remaining -= got;
    }
    return S_OK;
  }
  HRESULT STDMETHODCALLTYPE Commit(DWORD) override { return S_OK; }
  HRESULT STDMETHODCALLTYPE Revert() override { return STG_E_REVERTED; }
  HRESULT STDMETHODCALLTYPE LockRegion(ULARGE_INTEGER, ULARGE_INTEGER, DWORD) override { return STG_E_INVALIDFUNCTION; }
  HRESULT STDMETHODCALLTYPE UnlockRegion(ULARGE_INTEGER, ULARGE_INTEGER, DWORD) override { return STG_E_INVALIDFUNCTION; }
  HRESULT STDMETHODCALLTYPE Stat(STATSTG* value, DWORD flags) override {
    if (!value) return STG_E_INVALIDPOINTER;
    *value = {}; value->type = STGTY_STREAM; value->cbSize.QuadPart = file_.size; value->grfMode = STGM_READ;
    if (!(flags & STATFLAG_NONAME)) {
      value->pwcsName = static_cast<wchar_t*>(CoTaskMemAlloc((file_.relative_path.size() + 1) * sizeof(wchar_t)));
      if (!value->pwcsName) return E_OUTOFMEMORY;
      memcpy(value->pwcsName, file_.relative_path.c_str(), (file_.relative_path.size() + 1) * sizeof(wchar_t));
    }
    return S_OK;
  }
  HRESULT STDMETHODCALLTYPE Clone(IStream** output) override {
    if (!output) return E_POINTER;
    std::lock_guard<std::mutex> guard(mutex_);
    auto* clone = new RemoteStream(resolution_, file_); clone->offset_ = offset_; *output = clone; return S_OK;
  }
 private:
  ~RemoteStream() { if (handle_ != INVALID_HANDLE_VALUE) CloseHandle(handle_); ChangeLease(-1); }
  HRESULT Open() {
    if (handle_ != INVALID_HANDLE_VALUE) return S_OK;
    std::wstring root; const auto result = resolution_->Root(&root); if (FAILED(result)) return result;
    const auto slash = file_.relative_path.find_first_of(L"\\/");
    const auto path = slash == std::wstring::npos ? root : root + L"\\" + file_.relative_path.substr(slash + 1);
    handle_ = CreateFileW(path.c_str(), GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, nullptr, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
    return handle_ == INVALID_HANDLE_VALUE ? HRESULT_FROM_WIN32(GetLastError()) : S_OK;
  }
  std::atomic<ULONG> references_{1}; std::mutex mutex_;
  std::shared_ptr<Resolution> resolution_; GlobalSendRemoteFile file_;
  HANDLE handle_ = INVALID_HANDLE_VALUE; int64_t offset_ = 0;
};

class StreamApartment {
 public:
  StreamApartment() : thread_([this] {
    const auto initialized = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
    for (;;) {
      std::unique_lock<std::mutex> lock(mutex_);
      changed_.wait(lock, [this] { return stopping_ || !work_.empty(); });
      if (stopping_ && work_.empty()) break;
      auto action = std::move(work_.front()); work_.pop(); lock.unlock(); action(initialized);
    }
    if (SUCCEEDED(initialized)) CoUninitialize();
  }) {}
  ~StreamApartment() { { std::lock_guard<std::mutex> lock(mutex_); stopping_ = true; } changed_.notify_one(); thread_.join(); }
  HRESULT Create(const std::shared_ptr<Resolution>& resolution, const GlobalSendRemoteFile& file, IStream** output) {
    auto pending = std::make_shared<std::promise<std::pair<HRESULT, IStream*>>>();
    auto response = pending->get_future();
    {
      std::lock_guard<std::mutex> lock(mutex_);
      work_.push([pending, resolution, file](HRESULT initialized) {
        IStream* marshaled = nullptr; HRESULT result = initialized;
        if (SUCCEEDED(result)) {
          auto* stream = new RemoteStream(resolution, file);
          result = CoMarshalInterThreadInterfaceInStream(IID_IStream, stream, &marshaled);
          stream->Release();
        }
        pending->set_value({result, marshaled});
      });
    }
    changed_.notify_one();
    // This wait only marshals a lightweight object; no file/network operation
    // is performed until the target calls Read on the MTA-owned stream.
    const auto result = response.get();
    return FAILED(result.first) ? result.first : CoGetInterfaceAndReleaseStream(result.second, IID_PPV_ARGS(output));
  }
 private:
  std::mutex mutex_; std::condition_variable changed_;
  std::queue<std::function<void(HRESULT)>> work_;
  bool stopping_ = false; std::thread thread_;
};
StreamApartment& Streams() { static StreamApartment value; return value; }

class RemoteData final : public IDataObject, public IDataObjectAsyncCapability {
 public:
  RemoteData(IDataObject* shell, std::vector<GlobalSendRemoteFile> files, GlobalSendRemoteResolver resolve)
      : shell_(shell), files_(std::move(files)), resolution_(std::make_shared<Resolution>(std::move(resolve))) {}
  HRESULT STDMETHODCALLTYPE QueryInterface(REFIID iid, void** out) override {
    if (!out) return E_POINTER; *out = nullptr;
    if (iid == IID_IUnknown || iid == IID_IDataObject) *out = static_cast<IDataObject*>(this);
    else if (iid == IID_IDataObjectAsyncCapability) *out = static_cast<IDataObjectAsyncCapability*>(this);
    else return E_NOINTERFACE;
    AddRef(); return S_OK;
  }
  ULONG STDMETHODCALLTYPE AddRef() override { return ++references_; }
  ULONG STDMETHODCALLTYPE Release() override { const auto count = --references_; if (!count) delete this; return count; }
  HRESULT STDMETHODCALLTYPE QueryGetData(FORMATETC* format) override {
    if (!format) return E_POINTER;
    if (format->cfFormat == DescriptorFormat()) return (format->tymed & TYMED_HGLOBAL) ? S_OK : DV_E_TYMED;
    if (format->cfFormat == ContentsFormat()) return (format->tymed & TYMED_ISTREAM) && format->lindex >= 0 && static_cast<size_t>(format->lindex) < files_.size() && !files_[format->lindex].directory ? S_OK : DV_E_FORMATETC;
    return shell_->QueryGetData(format);
  }
  HRESULT STDMETHODCALLTYPE GetData(FORMATETC* format, STGMEDIUM* medium) override {
    if (!format || !medium) return E_POINTER;
    *medium = {};
    if (format->cfFormat != DescriptorFormat() && format->cfFormat != ContentsFormat()) return shell_->GetData(format, medium);
    const auto valid = QueryGetData(format); if (FAILED(valid)) return valid;
    if (format->cfFormat == ContentsFormat()) {
      const auto result = Streams().Create(resolution_, files_[format->lindex], &medium->pstm);
      if (SUCCEEDED(result)) medium->tymed = TYMED_ISTREAM;
      return result;
    }
    const auto bytes = sizeof(UINT) + files_.size() * sizeof(FILEDESCRIPTORW);
    medium->hGlobal = GlobalAlloc(GMEM_MOVEABLE | GMEM_ZEROINIT, bytes); if (!medium->hGlobal) return E_OUTOFMEMORY;
    auto* group = static_cast<FILEGROUPDESCRIPTORW*>(GlobalLock(medium->hGlobal));
    if (!group) { GlobalFree(medium->hGlobal); *medium = {}; return E_OUTOFMEMORY; }
    group->cItems = static_cast<UINT>(files_.size());
    for (size_t i = 0; i < files_.size(); ++i) {
      auto& item = group->fgd[i]; item.dwFlags = FD_ATTRIBUTES | FD_FILESIZE | FD_PROGRESSUI;
      item.dwFileAttributes = files_[i].directory ? FILE_ATTRIBUTE_DIRECTORY : FILE_ATTRIBUTE_NORMAL;
      item.nFileSizeHigh = static_cast<DWORD>(files_[i].size >> 32); item.nFileSizeLow = static_cast<DWORD>(files_[i].size);
      wcscpy_s(item.cFileName, files_[i].relative_path.c_str());
      for (auto& c : item.cFileName) if (c == L'/') c = L'\\';
    }
    GlobalUnlock(medium->hGlobal); medium->tymed = TYMED_HGLOBAL; return S_OK;
  }
  HRESULT STDMETHODCALLTYPE GetDataHere(FORMATETC*, STGMEDIUM*) override { return E_NOTIMPL; }
  HRESULT STDMETHODCALLTYPE GetCanonicalFormatEtc(FORMATETC* f, FORMATETC* out) override { return shell_->GetCanonicalFormatEtc(f, out); }
  HRESULT STDMETHODCALLTYPE SetData(FORMATETC* f, STGMEDIUM* m, BOOL own) override { return shell_->SetData(f, m, own); }
  HRESULT STDMETHODCALLTYPE EnumFormatEtc(DWORD direction, IEnumFORMATETC** out) override {
    if (direction != DATADIR_GET) return shell_->EnumFormatEtc(direction, out);
    std::vector<FORMATETC> formats{{DescriptorFormat(), nullptr, DVASPECT_CONTENT, -1, TYMED_HGLOBAL}, {ContentsFormat(), nullptr, DVASPECT_CONTENT, -1, TYMED_ISTREAM}};
    IEnumFORMATETC* extra = nullptr;
    if (SUCCEEDED(shell_->EnumFormatEtc(direction, &extra))) {
      FORMATETC value{}; while (extra->Next(1, &value, nullptr) == S_OK) formats.push_back(value); extra->Release();
    }
    return SHCreateStdEnumFmtEtc(static_cast<UINT>(formats.size()), formats.data(), out);
  }
  HRESULT STDMETHODCALLTYPE DAdvise(FORMATETC* f, DWORD flags, IAdviseSink* sink, DWORD* connection) override { return shell_->DAdvise(f, flags, sink, connection); }
  HRESULT STDMETHODCALLTYPE DUnadvise(DWORD value) override { return shell_->DUnadvise(value); }
  HRESULT STDMETHODCALLTYPE EnumDAdvise(IEnumSTATDATA** out) override { return shell_->EnumDAdvise(out); }
  HRESULT STDMETHODCALLTYPE SetAsyncMode(BOOL value) override { enabled_ = value != FALSE; return S_OK; }
  HRESULT STDMETHODCALLTYPE GetAsyncMode(BOOL* value) override { if (!value) return E_POINTER; *value = enabled_; return S_OK; }
  HRESULT STDMETHODCALLTYPE StartOperation(IBindCtx*) override { if (!running_.exchange(true)) { AddRef(); ChangeLease(1); } return S_OK; }
  HRESULT STDMETHODCALLTYPE InOperation(BOOL* value) override { if (!value) return E_POINTER; *value = running_; return S_OK; }
  HRESULT STDMETHODCALLTYPE EndOperation(HRESULT, IBindCtx*, DWORD) override { if (running_.exchange(false)) { ChangeLease(-1); Release(); } return S_OK; }
 private:
  ~RemoteData() { shell_->Release(); }
  std::atomic<ULONG> references_{1}; std::atomic<bool> enabled_{true}, running_{false};
  IDataObject* shell_; std::vector<GlobalSendRemoteFile> files_; std::shared_ptr<Resolution> resolution_;
};
}
bool GlobalSendRemoteDragBusy() { return provider_leases.load() != 0; }
void SetGlobalSendRemoteDragActivityChanged(std::function<void()> changed) {
  std::lock_guard<std::mutex> lock(activity_mutex); activity_changed = std::move(changed);
}
HRESULT CreateGlobalSendRemoteDragData(const std::vector<GlobalSendRemoteFile>& files,
    GlobalSendRemoteResolver resolve, IDataObject** output) {
  if (!output) return E_POINTER; *output = nullptr;
  if (files.empty() || !resolve) return E_INVALIDARG;
  for (const auto& file : files) if (!ValidRelative(file.relative_path)) return E_INVALIDARG;
  IDataObject* shell = nullptr; const auto result = SHCreateDataObject(nullptr, 0, nullptr, nullptr, IID_PPV_ARGS(&shell));
  if (FAILED(result)) return result;
  *output = new RemoteData(shell, files, std::move(resolve)); return S_OK;
}
