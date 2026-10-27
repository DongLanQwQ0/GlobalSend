#pragma once

#include <windows.h>
#include <wincrypt.h>
#include <cstdint>
#include <limits>
#include <vector>

// The persisted format remains current-user DPAPI, without optional entropy.
// Keep GetLastError immediately at the failing call; never include input bytes
// or decrypted output in an error/diagnostic message.
struct GlobalSendVaultResult {
  bool ok = false;
  DWORD windows_error = ERROR_SUCCESS;
  std::vector<uint8_t> bytes;
};

inline GlobalSendVaultResult GlobalSendVaultTransform(
    const std::vector<uint8_t>& bytes, bool seal,
    decltype(&CryptProtectData) protect = &CryptProtectData,
    decltype(&CryptUnprotectData) unprotect = &CryptUnprotectData) {
  GlobalSendVaultResult result;
  if (bytes.size() > (std::numeric_limits<DWORD>::max)()) {
    result.windows_error = ERROR_INVALID_PARAMETER;
    return result;
  }
  // DPAPI accepts an empty secret but still requires a non-null pbData. The
  // logout path intentionally stores an empty token rather than plaintext.
  BYTE empty = 0;
  DATA_BLOB input{static_cast<DWORD>(bytes.size()),
                  bytes.empty() ? &empty : const_cast<BYTE*>(bytes.data())};
  DATA_BLOB output{};
  result.ok = seal
      ? protect(&input, L"GlobalSend", nullptr, nullptr, nullptr,
                CRYPTPROTECT_UI_FORBIDDEN, &output)
      : unprotect(&input, nullptr, nullptr, nullptr, nullptr,
                  CRYPTPROTECT_UI_FORBIDDEN, &output);
  result.windows_error = result.ok ? ERROR_SUCCESS : GetLastError();
  if (result.ok && output.cbData > 0) {
    result.bytes.assign(output.pbData, output.pbData + output.cbData);
  }
  if (output.pbData) {
    SecureZeroMemory(output.pbData, output.cbData);
    LocalFree(output.pbData);
  }
  return result;
}
