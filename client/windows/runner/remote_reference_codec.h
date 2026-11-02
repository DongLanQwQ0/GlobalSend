#ifndef GLOBALSEND_REMOTE_REFERENCE_CODEC_H_
#define GLOBALSEND_REMOTE_REFERENCE_CODEC_H_
#include <flutter/standard_message_codec.h>
#include <cstring>
#include <optional>
#include <vector>
inline std::optional<flutter::EncodableMap> DecodeGlobalSendRemoteReference(const std::vector<uint8_t>& bytes) {
  if (bytes.size() < sizeof(uint32_t)) return {};
  uint32_t size = 0; memcpy(&size, bytes.data(), sizeof(size));
  if (size > bytes.size() - sizeof(size)) return {};
  const auto decoded = flutter::StandardMessageCodec::GetInstance().DecodeMessage(bytes.data() + sizeof(size), size);
  if (!decoded) return {};
  const auto* value = std::get_if<flutter::EncodableMap>(decoded.get());
  return value ? std::optional<flutter::EncodableMap>(*value) : std::nullopt;
}
#endif
