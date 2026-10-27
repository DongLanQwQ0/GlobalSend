#include "../runner/local_ip_interfaces.h"
#include <cassert>
#include <iostream>
#include <set>

int main() {
  const auto interfaces = ReadGlobalSendIpInterfaces();
  std::set<std::string> ids;
  for (const auto& adapter : interfaces) {
    assert(!adapter.id.empty());
    assert(ids.insert(adapter.id).second);
    assert(!adapter.name.empty());
    assert(!adapter.addresses.empty());
    std::cout << adapter.name << " | " << adapter.kind << " | " << adapter.description << '\n';
    for (const auto& ip : adapter.addresses) {
      assert(ip != "127.0.0.1" && ip != "::1");
      std::cout << "  " << ip << '\n';
    }
  }
  std::cout << "Enumerated " << interfaces.size() << " active interfaces from GetAdaptersAddresses\n";
}
