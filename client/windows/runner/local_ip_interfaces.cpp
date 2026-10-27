#include "local_ip_interfaces.h"

#include <winsock2.h>
#include <ws2tcpip.h>
#include <iphlpapi.h>
#include <windows.h>

#include <cstdint>
#include <stdexcept>
#include <vector>

namespace {
std::string Utf8(const wchar_t* value) {
  if (!value || !*value) return {};
  const int size = WideCharToMultiByte(CP_UTF8, 0, value, -1, nullptr, 0, nullptr, nullptr);
  std::string result(static_cast<size_t>(size), '\0');
  WideCharToMultiByte(CP_UTF8, 0, value, -1, result.data(), size, nullptr, nullptr);
  result.pop_back();
  return result;
}
std::string Kind(ULONG type) {
  switch (type) {
    case IF_TYPE_IEEE80211: return "Wi-Fi";
    case IF_TYPE_ETHERNET_CSMACD: return "以太网";
    case IF_TYPE_TUNNEL: return "隧道";
    case IF_TYPE_PPP: return "PPP";
    default: return "网卡";
  }
}
}

std::vector<GlobalSendIpInterface> ReadGlobalSendIpInterfaces() {
  constexpr ULONG flags = GAA_FLAG_SKIP_ANYCAST | GAA_FLAG_SKIP_MULTICAST |
      GAA_FLAG_SKIP_DNS_SERVER;
  ULONG size = 15 * 1024;
  // The OS can grow the buffer between size query and enumeration.
  std::vector<uint8_t> storage(size);
  ULONG status = GetAdaptersAddresses(AF_UNSPEC, flags, nullptr,
      reinterpret_cast<IP_ADAPTER_ADDRESSES*>(storage.data()), &size);
  if (status == ERROR_BUFFER_OVERFLOW) {
    storage.resize(size);
    status = GetAdaptersAddresses(AF_UNSPEC, flags, nullptr,
        reinterpret_cast<IP_ADAPTER_ADDRESSES*>(storage.data()), &size);
  }
  if (status == ERROR_NO_DATA) return {};
  if (status != NO_ERROR) throw std::runtime_error("无法读取网卡地址");
  std::vector<GlobalSendIpInterface> result;
  for (auto* adapter = reinterpret_cast<IP_ADAPTER_ADDRESSES*>(storage.data());
       adapter; adapter = adapter->Next) {
    if (adapter->IfType == IF_TYPE_SOFTWARE_LOOPBACK ||
        adapter->OperStatus != IfOperStatusUp) continue;
    GlobalSendIpInterface item;
    item.id = adapter->AdapterName ? adapter->AdapterName : "";
    item.name = Utf8(adapter->FriendlyName);
    item.description = Utf8(adapter->Description);
    item.kind = Kind(adapter->IfType);
    for (auto* unicast = adapter->FirstUnicastAddress; unicast; unicast = unicast->Next) {
      if (unicast->DadState == IpDadStateInvalid ||
          unicast->DadState == IpDadStateDuplicate ||
          unicast->DadState == IpDadStateTentative) continue;
      const auto* address = unicast->Address.lpSockaddr;
      char text[INET6_ADDRSTRLEN]{};
      if (address->sa_family == AF_INET) {
        const auto* ipv4 = reinterpret_cast<const sockaddr_in*>(address);
        if (InetNtopA(AF_INET, &ipv4->sin_addr, text, sizeof(text)))
          item.addresses.emplace_back(text);
      } else if (address->sa_family == AF_INET6) {
        const auto* ipv6 = reinterpret_cast<const sockaddr_in6*>(address);
        if (InetNtopA(AF_INET6, &ipv6->sin6_addr, text, sizeof(text))) {
          std::string scoped(text);
          if (ipv6->sin6_scope_id != 0)
            scoped += "%" + std::to_string(ipv6->sin6_scope_id);
          item.addresses.push_back(std::move(scoped));
        }
      }
    }
    if (!item.addresses.empty()) result.push_back(std::move(item));
  }
  return result;
}
