#include "clipboard_image.h"
#include <wincodec.h>
#include <wrl/client.h>
#include <objidl.h>
#include <cstring>
#include <cstdint>
#include <limits>

using Microsoft::WRL::ComPtr;

GlobalSendClipboardImage PrepareGlobalSendClipboardImage(const std::wstring& path) {
  GlobalSendClipboardImage image;
  ComPtr<IWICImagingFactory> factory;
  ComPtr<IWICBitmapDecoder> decoder;
  ComPtr<IWICBitmapFrameDecode> frame;
  ComPtr<IWICFormatConverter> pixels;
  auto status = CoCreateInstance(CLSID_WICImagingFactory, nullptr,
      CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&factory));
  if (SUCCEEDED(status)) status = factory->CreateDecoderFromFilename(path.c_str(),
      nullptr, GENERIC_READ, WICDecodeMetadataCacheOnLoad, &decoder);
  if (SUCCEEDED(status)) status = decoder->GetFrame(0, &frame);
  if (SUCCEEDED(status)) status = factory->CreateFormatConverter(&pixels);
  if (SUCCEEDED(status)) status = pixels->Initialize(frame.Get(), GUID_WICPixelFormat32bppBGRA,
      WICBitmapDitherTypeNone, nullptr, 0, WICBitmapPaletteTypeCustom);
  UINT width = 0, height = 0;
  if (SUCCEEDED(status)) status = pixels->GetSize(&width, &height);
  // WIC and clipboard DIBs use 32-bit buffer sizes; reject integer overflow.
  const auto length = static_cast<uint64_t>(width) * height * 4;
  if (SUCCEEDED(status) && (!width || !height ||
      width > static_cast<UINT>(std::numeric_limits<LONG>::max()) ||
      height > static_cast<UINT>(std::numeric_limits<LONG>::max()) ||
      length > std::numeric_limits<UINT>::max() - sizeof(BITMAPV5HEADER))) status = E_INVALIDARG;
  if (SUCCEEDED(status)) {
    BITMAPV5HEADER header{};
    header.bV5Size = sizeof(header);
    header.bV5Width = static_cast<LONG>(width);
    header.bV5Height = -static_cast<LONG>(height);
    header.bV5Planes = 1;
    header.bV5BitCount = 32;
    header.bV5Compression = BI_BITFIELDS;
    header.bV5RedMask = 0x00ff0000;
    header.bV5GreenMask = 0x0000ff00;
    header.bV5BlueMask = 0x000000ff;
    header.bV5AlphaMask = 0xff000000;
    header.bV5CSType = LCS_sRGB;
    header.bV5SizeImage = static_cast<DWORD>(length);
    image.dib_v5.resize(sizeof(header) + static_cast<size_t>(length));
    memcpy(image.dib_v5.data(), &header, sizeof(header));
    status = pixels->CopyPixels(nullptr, width * 4, static_cast<UINT>(length),
        image.dib_v5.data() + sizeof(header));
    if (SUCCEEDED(status)) {
      BITMAPINFOHEADER legacy{};
      legacy.biSize = sizeof(legacy);
      legacy.biWidth = header.bV5Width;
      legacy.biHeight = header.bV5Height;
      legacy.biPlanes = 1;
      legacy.biBitCount = 32;
      legacy.biCompression = BI_RGB;
      legacy.biSizeImage = header.bV5SizeImage;
      image.dib.resize(sizeof(legacy) + static_cast<size_t>(length));
      memcpy(image.dib.data(), &legacy, sizeof(legacy));
      memcpy(image.dib.data() + sizeof(legacy), image.dib_v5.data() + sizeof(header),
          static_cast<size_t>(length));
    }
  }
  ComPtr<IStream> stream;
  ComPtr<IWICBitmapEncoder> encoder;
  ComPtr<IWICBitmapFrameEncode> encoded;
  if (SUCCEEDED(status)) status = CreateStreamOnHGlobal(nullptr, TRUE, &stream);
  if (SUCCEEDED(status)) status = factory->CreateEncoder(GUID_ContainerFormatPng, nullptr, &encoder);
  if (SUCCEEDED(status)) status = encoder->Initialize(stream.Get(), WICBitmapEncoderNoCache);
  if (SUCCEEDED(status)) status = encoder->CreateNewFrame(&encoded, nullptr);
  if (SUCCEEDED(status)) status = encoded->Initialize(nullptr);
  if (SUCCEEDED(status)) status = encoded->SetSize(width, height);
  WICPixelFormatGUID format = GUID_WICPixelFormat32bppBGRA;
  if (SUCCEEDED(status)) status = encoded->SetPixelFormat(&format);
  if (SUCCEEDED(status)) status = encoded->WriteSource(pixels.Get(), nullptr);
  if (SUCCEEDED(status)) status = encoded->Commit();
  if (SUCCEEDED(status)) status = encoder->Commit();
  if (SUCCEEDED(status)) {
    STATSTG info{};
    status = stream->Stat(&info, STATFLAG_NONAME);
    HGLOBAL memory = nullptr;
    if (SUCCEEDED(status)) status = GetHGlobalFromStream(stream.Get(), &memory);
    if (SUCCEEDED(status)) {
      const auto* bytes = static_cast<const unsigned char*>(GlobalLock(memory));
      if (!bytes) status = E_OUTOFMEMORY;
      else {
        image.png.assign(bytes, bytes + static_cast<size_t>(info.cbSize.QuadPart));
        GlobalUnlock(memory);
      }
    }
  }
  image.status = status;
  return image;
}
