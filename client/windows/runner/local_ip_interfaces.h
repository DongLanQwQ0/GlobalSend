#ifndef GLOBALSEND_LOCAL_IP_INTERFACES_H_
#define GLOBALSEND_LOCAL_IP_INTERFACES_H_

#include <string>
#include <vector>

struct GlobalSendIpInterface {
  std::string id;
  std::string name;
  std::string description;
  std::string kind;
  std::vector<std::string> addresses;
};

// OS-reported adapter names/descriptions only, never inferred process owners.
std::vector<GlobalSendIpInterface> ReadGlobalSendIpInterfaces();

#endif
