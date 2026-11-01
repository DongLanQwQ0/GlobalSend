#include "../runner/auto_update.h"
#include <cassert>

int main() {
  // Automatic installation must stay background even when Alt+Tab leaves the
  // old window visible. Only an explicit action may restore its visible state.
  assert(GlobalSendUpdateBackground(false, true));
  assert(GlobalSendUpdateBackground(false, false));
  assert(!GlobalSendUpdateBackground(true, true));
  assert(GlobalSendUpdateBackground(true, false));
  return 0;
}
