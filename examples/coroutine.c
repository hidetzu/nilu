/* A coroutine driven by the host: the program's function yields values, and
 * the host resumes it until it returns.
 *
 *   zig build example
 */
#include <stdio.h>

#include "nilu.h"

int main(void) {
  NiluState *N = nilu_new();
  if (N == NULL) return 1;
  if (nilu_openlibs(N) != NILU_OK) {
    nilu_close(N);
    return 1;
  }

  const char *source =
      "function squares(n)\n"
      "  for i = 1, n do coroutine.yield(i * i) end\n"
      "  return 'finished'\n"
      "end";
  if (nilu_loadstring(N, source, NULL) != NILU_OK || nilu_pcall(N, 0, 0, 0) != NILU_OK) {
    nilu_close(N);
    return 1;
  }

  /* The thread replaces the function on the stack; it stays at index 1. */
  if (nilu_getglobal(N, "squares") != NILU_OK || nilu_newthread(N) != NILU_OK) {
    nilu_close(N);
    return 1;
  }
  int thread = nilu_gettop(N);

  /* The first resume passes the function's arguments; later ones pass what
   * the yield answers, here nothing. */
  if (nilu_pushinteger(N, 4) != NILU_OK) {
    nilu_close(N);
    return 1;
  }
  int nargs = 1;
  for (;;) {
    int nresults = 0;
    NiluStatus status = nilu_resume(N, thread, nargs, &nresults);
    nargs = 0;
    if (status == NILU_YIELD) {
      printf("yielded %lld\n", (long long)nilu_tointeger(N, -1));
      nilu_pop(N, nresults);
    } else if (status == NILU_OK) {
      printf("returned %s\n", nilu_tostring(N, -1));
      nilu_pop(N, nresults);
      break;
    } else {
      const char *message = nilu_tostring(N, -1);
      printf("failed: %s\n", message != NULL ? message : "(no sentence)");
      break;
    }
  }
  printf("status after: %s\n", nilu_threadstatus(N, thread) == NILU_THREAD_DEAD ? "dead" : "not dead");

  nilu_close(N);
  return 0;
}
