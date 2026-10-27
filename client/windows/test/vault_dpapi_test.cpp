#include "../runner/vault_dpapi.h"
#include <cassert>
#include <iostream>

#pragma comment(lib, "Crypt32.lib")

DWORD observed_flags = 0;
BOOL WINAPI FailedProtect(DATA_BLOB*, LPCWSTR, DATA_BLOB*, PVOID,
    CRYPTPROTECT_PROMPTSTRUCT*, DWORD flags, DATA_BLOB* output) {
  observed_flags = flags;
  output->cbData = 8;
  output->pbData = static_cast<BYTE*>(LocalAlloc(LMEM_FIXED, output->cbData));
  SetLastError(static_cast<DWORD>(NTE_BAD_KEY_STATE));
  return FALSE;
}
BOOL WINAPI FailedUnprotect(DATA_BLOB*, LPWSTR*, DATA_BLOB*, PVOID,
    CRYPTPROTECT_PROMPTSTRUCT*, DWORD flags, DATA_BLOB*) {
  observed_flags = flags;
  SetLastError(ERROR_INVALID_DATA);
  return FALSE;
}

int main() {
  // Synthetic public fixture only. Never load a user's credential or private key.
  const std::vector<uint8_t> fixture{71, 83, 0, 1, 2, 255};
  auto sealed = GlobalSendVaultTransform(fixture, true);
  assert(sealed.ok && sealed.windows_error == 0 && sealed.bytes != fixture);
  auto opened = GlobalSendVaultTransform(sealed.bytes, false);
  assert(opened.ok && opened.windows_error == 0 && opened.bytes == fixture);
  SecureZeroMemory(opened.bytes.data(), opened.bytes.size());
  auto empty = GlobalSendVaultTransform({}, true);
  assert(empty.ok);
  auto empty_opened = GlobalSendVaultTransform(empty.bytes, false);
  assert(empty_opened.ok && empty_opened.bytes.empty());
  auto invalid = GlobalSendVaultTransform({0, 1, 2}, false);
  assert(!invalid.ok && invalid.windows_error != ERROR_SUCCESS && invalid.bytes.empty());
  auto failed_seal = GlobalSendVaultTransform(fixture, true, FailedProtect);
  assert(!failed_seal.ok && failed_seal.windows_error == static_cast<DWORD>(NTE_BAD_KEY_STATE));
  assert(failed_seal.bytes.empty() && observed_flags == CRYPTPROTECT_UI_FORBIDDEN);
  auto failed_unseal = GlobalSendVaultTransform(fixture, false, &CryptProtectData, FailedUnprotect);
  assert(!failed_unseal.ok && failed_unseal.windows_error == ERROR_INVALID_DATA);
  assert(failed_unseal.bytes.empty() && observed_flags == CRYPTPROTECT_UI_FORBIDDEN);
  std::cout << "PASS: current-user DPAPI roundtrip, empty values, invalid protected bytes, exact seal/unseal errors, no machine-scope fallback\n";
}
